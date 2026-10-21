"""Exercise the real PostgreSQL migration with isolated Supabase-like auth roles.

Only a local disposable database named formscan_test is accepted. No production
Supabase credentials or real users are used by this test suite.
"""
import concurrent.futures
import json
import os
import pathlib
import unittest
import uuid

import psycopg
from psycopg.conninfo import conninfo_to_dict
from psycopg.types.json import Jsonb

DSN = os.environ.get('FORMSCAN_TEST_DSN', 'host=127.0.0.1 port=15432 dbname=formscan_test user=postgres password=formscan-test-only')
CONFIG = conninfo_to_dict(DSN)
assert CONFIG.get('host') in ('127.0.0.1', 'localhost', 'postgres')
assert CONFIG.get('dbname') == 'formscan_test', 'Only the disposable local test database is permitted'
USER_A, USER_B = uuid.UUID(int=1), uuid.UUID(int=2)
MIGRATION = (pathlib.Path(__file__).parents[1] / '001_document_cloud.sql').read_text()


def connection(owner=USER_A, role='authenticated'):
    db = psycopg.connect(DSN)
    db.execute('select set_config(%s, %s, true)', ('request.jwt.claim.sub', str(owner) if owner else ''))
    assert role in ('authenticated', 'anon')
    db.execute('set local role ' + role)
    return db


def metadata(doc):
    return {'id': str(doc), 'title': 'Fixture', 'pageCount': 1, 'fields': [], 'modified': 0}


def object_path(owner, doc, revision):
    return f'{owner}/{doc}/{revision}.pdf'


def upload(owner, doc, revision):
    path = object_path(owner, doc, revision)
    with connection(owner) as db:
        db.execute('insert into storage.objects(bucket_id,name) values(%s,%s)', ('formscan-documents', path))
    return path


def commit(owner, doc, revision, expected=None, path=None, value=None, deleted=False):
    with connection(owner) as db:
        return db.execute('select public.formscan_commit_document(%s,%s,%s,%s,%s,%s)',
                          (doc, expected, revision, path, Jsonb(value) if value is not None else None, deleted)).fetchone()[0]


class CloudPermissionsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with psycopg.connect(DSN, autocommit=True) as db:
            db.execute('''
              do $$ begin
                if not exists(select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
                if not exists(select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
              end $$;
              create schema if not exists auth;
              create schema if not exists storage;
              create table if not exists auth.users(id uuid primary key);
              create or replace function auth.uid() returns uuid language sql stable as
                $$ select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;
              create table if not exists storage.buckets(id text primary key,name text,public boolean,
                file_size_limit bigint,allowed_mime_types text[]);
              create table if not exists storage.objects(bucket_id text,name text,primary key(bucket_id,name));
              alter table storage.objects enable row level security;
              create or replace function storage.foldername(name text) returns text[] language sql immutable as
                $$ select string_to_array(name,'/') $$;
              grant usage on schema public,auth,storage to anon,authenticated;
              grant execute on function auth.uid(),storage.foldername(text) to anon,authenticated;
              grant select,insert,delete on storage.objects to authenticated;
            ''')
            db.execute(MIGRATION)
            db.execute(MIGRATION)

    def setUp(self):
        with psycopg.connect(DSN) as db:
            db.execute('delete from public.formscan_documents')
            db.execute('delete from storage.objects')
            db.execute('insert into auth.users(id) values(%s),(%s) on conflict do nothing', (USER_A, USER_B))

    def make_document(self, owner=USER_A):
        doc, revision = uuid.uuid4(), uuid.uuid4()
        path = upload(owner, doc, revision)
        result = commit(owner, doc, revision, path=path, value=metadata(doc))
        self.assertEqual(result['status'], 'saved')
        return doc, revision, path

    def test_public_health_contains_only_installation_status(self):
        with connection(None, 'anon') as db:
            health = db.execute('select public.formscan_cloud_health()').fetchone()[0]
        self.assertEqual(health, {'schemaVersion': 1, 'privateBucket': True})

    def test_other_account_cannot_read_catalogue_or_private_object(self):
        doc, revision, path = self.make_document()
        with connection(USER_B) as db:
            self.assertEqual(db.execute('select count(*) from public.formscan_documents').fetchone()[0], 0)
            self.assertEqual(db.execute('select count(*) from storage.objects where name=%s', (path,)).fetchone()[0], 0)
        with connection(USER_A) as db:
            self.assertEqual(db.execute('select id from public.formscan_documents').fetchone()[0], doc)

    def test_anonymous_catalogue_and_commit_are_denied(self):
        self.make_document()
        with self.assertRaises(psycopg.errors.InsufficientPrivilege):
            with connection(None, 'anon') as db:
                db.execute('select * from public.formscan_documents')
        with self.assertRaises(psycopg.errors.InsufficientPrivilege):
            with connection(None, 'anon') as db:
                db.execute('select public.formscan_commit_document(%s,null,%s,null,null,true)', (uuid.uuid4(), uuid.uuid4()))

    def test_authenticated_cannot_bypass_cas_or_upload_to_foreign_prefix(self):
        with self.assertRaises(psycopg.errors.InsufficientPrivilege):
            with connection(USER_A) as db:
                db.execute('insert into public.formscan_documents(user_id,id,revision,metadata) values(%s,%s,%s,%s)',
                           (USER_A, uuid.uuid4(), uuid.uuid4(), Jsonb({})))
        with self.assertRaises(psycopg.errors.InsufficientPrivilege):
            self.foreign_upload()

    def foreign_upload(self):
        with connection(USER_A) as db:
            db.execute('insert into storage.objects(bucket_id,name) values(%s,%s)',
                       ('formscan-documents', object_path(USER_B, uuid.uuid4(), uuid.uuid4())))

    def test_pdf_must_exist_and_metadata_cannot_reference_another_owner(self):
        doc, revision = uuid.uuid4(), uuid.uuid4()
        with self.assertRaises(psycopg.errors.InvalidParameterValue):
            commit(USER_A, doc, revision, path=object_path(USER_A, doc, revision), value=metadata(doc))
        other = upload(USER_B, doc, revision)
        with self.assertRaises(psycopg.errors.InvalidParameterValue):
            commit(USER_A, doc, revision, path=other, value=metadata(doc))

    def test_stale_revision_does_not_replace_saved_document(self):
        doc, revision, path = self.make_document()
        next_revision = uuid.uuid4(); next_path = upload(USER_A, doc, next_revision)
        result = commit(USER_A, doc, next_revision, expected=uuid.uuid4(), path=next_path, value=metadata(doc))
        self.assertEqual(result['status'], 'conflict')
        self.assertEqual(result['document']['revision'], str(revision))

    def test_retry_is_idempotent_but_cannot_reuse_revision_for_other_data(self):
        doc, revision, path = self.make_document()
        self.assertEqual(commit(USER_A, doc, revision, path=path, value=metadata(doc))['status'], 'saved')
        modified = metadata(doc); modified['title'] = 'Changed without a revision'
        with self.assertRaises(psycopg.errors.InvalidParameterValue):
            commit(USER_A, doc, revision, path=path, value=modified)

    def test_delete_is_a_tombstone_and_old_edit_cannot_resurrect_it(self):
        doc, revision, path = self.make_document()
        tombstone = uuid.uuid4()
        self.assertEqual(commit(USER_A, doc, tombstone, expected=revision, deleted=True)['status'], 'saved')
        with connection(USER_A) as db:
            self.assertIsNotNone(db.execute('select deleted_at from public.formscan_documents').fetchone()[0])
        stale = uuid.uuid4(); stale_path = upload(USER_A, doc, stale)
        self.assertEqual(commit(USER_A, doc, stale, expected=revision, path=stale_path, value=metadata(doc))['status'], 'conflict')

    def test_parallel_writers_accept_exactly_one_revision(self):
        doc, revision, path = self.make_document()
        versions = [(new, upload(USER_A, doc, new)) for new in (uuid.uuid4(), uuid.uuid4())]
        def writer(value):
            new, key = value
            return commit(USER_A, doc, new, expected=revision, path=key, value=metadata(doc))['status']
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            self.assertEqual(sorted(pool.map(writer, versions)), ['conflict', 'saved'])

    def test_signed_in_role_without_identity_cannot_commit(self):
        with self.assertRaises(psycopg.errors.InsufficientPrivilege):
            commit(None, uuid.uuid4(), uuid.uuid4(), deleted=True)


if __name__ == '__main__':
    unittest.main(verbosity=2)
