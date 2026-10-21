# FormScan

App nativa para iPhone y iPad con **iOS 26 o posterior**, SwiftUI y Liquid Glass. Escanea, importa, completa y comparte documentos. El análisis de campos ocurre en el dispositivo; con una cuenta, los PDF y sus campos se guardan de forma privada para poder recuperarlos.

## Instalación con SideStore

Añade esta fuente en SideStore:

```text
https://raw.githubusercontent.com/polaca1/FormScan/main/source.json
```

También se mantiene `sidestore-v2.json`. Ambas fuentes describen la misma IPA, con la versión y el tamaño leídos del paquete real. La descarga de [Releases](https://github.com/polaca1/FormScan/releases) se distribuye sin firmar y SideStore la firma al instalar. El identificador se mantiene: `com.polaca1.formscan`. Actualiza sobre la instalación existente para conservar los cambios que todavía estén pendientes de subir.

## Uso

- La primera apertura ofrece acceso con Google o correo y un tutorial con documento de ejemplo. También permite continuar sin cuenta, con documentos locales.
- **Inicio** permite escanear, importar o probar un ejemplo. **Documentos** reúne la biblioteca y la búsqueda. **Ajustes** contiene cuenta, privacidad y primeros pasos.
- El escáner nativo captura varias páginas. Archivos permite importar PDF e imágenes. La detección empieza automáticamente y se puede repetir conservando los valores existentes.
- **Formulario** permite escribir y marcar casillas. Los cambios aparecen en **Documento**. Las etiquetas de tablas combinan los encabezados de fila y columna; no se prolongan las filas fuera de los bordes impresos. [Detalles y límites](Docs/Tables.md).
- Los ajustes de cada campo permiten cambiar su etiqueta, contenido, tamaño y posición. Las casillas mantienen su tipo y una marca visible en el PDF.
- **Compartir** genera un PDF con el contenido incorporado. El original editable permanece en la biblioteca.
- Con una cuenta, el guardado y la recuperación son automáticos. Se puede editar sin conexión y reintentar los envíos pendientes. Los cambios simultáneos conservan ambas versiones y los errores de guardado siguen siendo visibles.

Iniciar sesión no demuestra por sí solo que los últimos cambios ya se hayan enviado. Resuelve cualquier aviso de guardado antes de eliminar la app; exporta los documentos importantes si necesitas conservar otra copia.

## Cuenta y almacenamiento

FormScan utiliza un proyecto Supabase independiente de reviewNfcGo. Solo la configuración pública forma parte de la app. Google OAuth usa PKCE y el navegador del sistema; las sesiones se guardan mediante el SDK oficial en el llavero. El acceso a los documentos depende del UUID autenticado y de políticas privadas del servicio.

[Configuración de acceso](Docs/Accounts.md) · [SQL, almacenamiento, conflictos y límites](Docs/Cloud.md).

El propietario debe ejecutar [Backend/001_document_cloud.sql](Backend/001_document_cloud.sql) en el SQL Editor de su proyecto y configurar Google, las redirecciones y el correo. El bucket privado admite PDF de hasta 50 MiB. Se aplican las cuotas y las condiciones del plan de Supabase. El análisis local sigue funcionando sin descargas ni opciones técnicas en la interfaz.

## Diseño

Se aplican las [guías oficiales de Apple](Docs/Design.md) y la [adaptación para iOS 27](Docs/iOS27.md): pestañas nativas, editor a pantalla completa, colores semánticos, modos claro/oscuro, texto de accesibilidad y movimiento reducido. Documento y Formulario mantienen sus vistas vivas al cambiar de modo para conservar zoom, posición y barras.

## Compilar y verificar

Requiere macOS, **Xcode 26.6 o posterior**, XcodeGen y Python 3.12. Actions compila y prueba iOS 26 y 27; la IPA distribuida usa el SDK 27 y conserva iOS 26 como mínimo.

```sh
brew install xcodegen
python3 -m venv .build-tools
.build-tools/bin/pip install onnx==1.23.2 numpy==2.3.5 zstandard==0.25.0
.build-tools/bin/python Scripts/prepare_models.py
.build-tools/bin/python Scripts/prepare_accounts.py
swift Scripts/GenerateIcon.swift
xcodegen generate
xcodebuild -project FormScan.xcodeproj -scheme FormScan -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

La batería incluye pruebas de PDF, recursos de inferencia reales, tablas, cuentas, transporte HTTP, recuperación, conflictos y escrituras simultáneas. Las pruebas nativas de interfaz cubren Archivos, reapertura, edición, casillas, exportación, accesibilidad y recuperación tras eliminar la biblioteca local de prueba. Sus capturas y resultados se conservan en los artefactos `FormScan-build-and-verification-iOS26` e `iOS27`.

Los servicios de prueba están aislados. El acceso Google, la entrega de correo, la nube con una cuenta real, la cámara y la instalación física requieren comprobación en un dispositivo; los resultados del simulador no sustituyen esas pruebas.

## Publicación y recursos

La publicación exige verificaciones completas y genera las fuentes desde **Info.plist dentro de la IPA**. Las descargas usan URLs de versión. Una actualización cambia `MARKETING_VERSION` y `CURRENT_PROJECT_VERSION` en `project.yml`; las fuentes se regeneran automáticamente después de comprobar la descarga publicada.

Los tres recursos de inferencia se incluyen y verifican por SHA-256 durante la preparación. Su ejecución se adapta internamente a la memoria, la energía y la temperatura del dispositivo. [Investigación técnica y licencias](Docs/Models.md) · [Avisos de terceros](Sources/Resources/ThirdPartyNotices.txt). Los iconos originales tienen apariencias clara y oscura; iOS aplica la apariencia tintada del sistema.
