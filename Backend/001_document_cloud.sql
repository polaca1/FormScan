-- FormScan: private PDF storage, owner-only catalogue, revision-checked commits.
-- Run once in the SQL Editor of the FormScan project. Safe to run again.
begin;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('formscan-documents', 'formscan-documents', false, 52428800, array['application/pdf'])
on conflict (id) do update set public = false, file_size_limit = 52428800,
  allowed_mime_types = array['application/pdf'];

create table if not exists public.formscan_documents (
  user_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null,
  revision uuid not null,
  object_key text,
  metadata jsonb not null,
  deleted_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (user_id, id)
);
alter table public.formscan_documents enable row level security;
revoke all on public.formscan_documents from anon, authenticated;
grant select on public.formscan_documents to authenticated;
drop policy if exists formscan_owner_read on public.formscan_documents;
create policy formscan_owner_read on public.formscan_documents for select to authenticated
  using ((select auth.uid()) = user_id);

-- Files are immutable revisions. Updating the catalogue is a separate atomic RPC.
drop policy if exists formscan_pdf_read on storage.objects;
create policy formscan_pdf_read on storage.objects for select to authenticated
  using (bucket_id = 'formscan-documents' and (storage.foldername(name))[1] = (select auth.uid())::text);
drop policy if exists formscan_pdf_insert on storage.objects;
create policy formscan_pdf_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'formscan-documents' and (storage.foldername(name))[1] = (select auth.uid())::text);
drop policy if exists formscan_pdf_delete on storage.objects;
create policy formscan_pdf_delete on storage.objects for delete to authenticated
  using (bucket_id = 'formscan-documents' and (storage.foldername(name))[1] = (select auth.uid())::text);

create or replace function public.formscan_commit_document(
  p_id uuid, p_expected_revision uuid, p_revision uuid,
  p_object_key text, p_metadata jsonb, p_deleted boolean
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  owner_id uuid := auth.uid();
  current_record public.formscan_documents%rowtype;
  found_record boolean;
  expected_key text;
begin
  if owner_id is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  if p_id is null or p_revision is null or p_deleted is null then
    raise exception 'Invalid document' using errcode = '22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(owner_id::text || ':' || p_id::text, 0));
  select * into current_record from public.formscan_documents where user_id = owner_id and id = p_id for update;
  found_record := found;
  if found_record and current_record.revision = p_revision then
    if (current_record.deleted_at is not null) <> p_deleted or
       (not p_deleted and (current_record.object_key is distinct from p_object_key or current_record.metadata is distinct from p_metadata)) then
      raise exception 'Revision already used' using errcode = '22023';
    end if;
    return pg_catalog.jsonb_build_object('status', 'saved', 'document', pg_catalog.to_jsonb(current_record));
  end if;
  if (found_record and current_record.revision is distinct from p_expected_revision) or
     (not found_record and p_expected_revision is not null) then
    return pg_catalog.jsonb_build_object('status', 'conflict', 'document', case when found_record then pg_catalog.to_jsonb(current_record) else null end);
  end if;
  if p_deleted then
    if not found_record then return pg_catalog.jsonb_build_object('status', 'missing'); end if;
    update public.formscan_documents set revision = p_revision, deleted_at = pg_catalog.clock_timestamp(),
      updated_at = pg_catalog.clock_timestamp() where user_id = owner_id and id = p_id returning * into current_record;
  else
    expected_key := owner_id::text || '/' || p_id::text || '/' || p_revision::text || '.pdf';
    if p_object_key is distinct from expected_key or
       pg_catalog.jsonb_typeof(p_metadata) is distinct from 'object' or
       pg_catalog.lower(p_metadata->>'id') is distinct from p_id::text or
       pg_catalog.jsonb_typeof(p_metadata->'fields') is distinct from 'array' or
       pg_catalog.pg_column_size(p_metadata) > 2097152 then
      raise exception 'Invalid document metadata' using errcode = '22023';
    end if;
    if not exists (select 1 from storage.objects where bucket_id = 'formscan-documents' and name = expected_key) then
      raise exception 'PDF must be uploaded first' using errcode = '22023';
    end if;
    insert into public.formscan_documents(user_id, id, revision, object_key, metadata)
      values(owner_id, p_id, p_revision, p_object_key, p_metadata)
      on conflict(user_id, id) do update set revision = excluded.revision, object_key = excluded.object_key,
        metadata = excluded.metadata, deleted_at = null, updated_at = pg_catalog.clock_timestamp()
      returning * into current_record;
  end if;
  return pg_catalog.jsonb_build_object('status', 'saved', 'document', pg_catalog.to_jsonb(current_record));
end;
$$;
revoke all on function public.formscan_commit_document(uuid, uuid, uuid, text, jsonb, boolean) from public, anon;
grant execute on function public.formscan_commit_document(uuid, uuid, uuid, text, jsonb, boolean) to authenticated;

-- Public installation check only: no user records, names or object paths returned.
create or replace function public.formscan_cloud_health() returns jsonb
language sql stable security definer set search_path = '' as $$
  select pg_catalog.jsonb_build_object('schemaVersion', 1, 'privateBucket',
    exists(select 1 from storage.buckets where id = 'formscan-documents' and public = false));
$$;
revoke all on function public.formscan_cloud_health() from public;
grant execute on function public.formscan_cloud_health() to anon, authenticated;

commit;
