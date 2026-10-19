# FormScan

Aplicación nativa para iPhone y iPad con **iOS 26 o posterior**, SwiftUI y Liquid Glass. Escanea documentos, importa PDF e imágenes, identifica campos mediante IA local y exporta el resultado en PDF.

## Instalación con SideStore

Añade esta fuente en SideStore:

```
https://raw.githubusercontent.com/polaca1/FormScan/main/source.json
```

También se mantiene `sidestore-v2.json` para instalaciones que ya utilizan esa dirección. Ambas fuentes describen exactamente la misma IPA. Si conservas una fuente antigua en caché con versión `1.0` o `1.0.0`, elimínala de SideStore y añade la dirección anterior de nuevo. Los documentos creados con FormScan 2 se guardan en el dispositivo.

La IPA de [Releases](https://github.com/polaca1/FormScan/releases) se distribuye **sin firmar**: SideStore debe firmarla al instalar. El identificador sigue siendo `com.polaca1.formscan`.

## Uso

- El primer inicio muestra un tutorial con un formulario de ejemplo. Puedes repetirlo desde **Ajustes → Primeros pasos**.
- La app tiene tres pestañas: **Inicio** para escanear/importar, **Documentos** con biblioteca y búsqueda, y **Ajustes** con modelos y tutorial. El editor es una tarea modal a pantalla completa y vuelve a Documentos al cerrarse.
- **Escanear** abre el escáner nativo a pantalla completa; **Importar** permite elegir PDF o imágenes de Archivos.
- El análisis empieza automáticamente al importar o escanear, sin enviar el documento a un servidor. **Detectar** permite repetirlo y conserva los valores existentes. Los campos PDF interactivos se reconocen al importar.
- **Formulario** permite escribir y marcar casillas. Los cambios aparecen inmediatamente en **Documento** y se guardan automáticamente. Volver a detectar conserva los datos existentes.
- Toca un campo en el documento o sus ajustes para cambiar etiqueta, contenido y tamaño. **Colocar en el documento** permite situarlo tocando cualquier página.
- **Compartir** genera una copia PDF con el contenido incorporado, para que se vea en lectores que no admiten formularios interactivos. El original editable permanece en la biblioteca.
- **Probar un ejemplo**, en Inicio, permite probar el flujo sin cámara.

## Diseño

Se aplica la guía oficial de Apple: navegación con pestañas nativas, contenido separado de los controles, barras con acciones limitadas y transiciones breves que respetan Reducir movimiento. [Pautas concretas aplicadas y fuentes oficiales](Docs/Design.md). Las vistas PDF y Formulario se mantienen vivas al alternar para conservar zoom, posición y geometría de la barra.

## Modelos de IA

**Nano equilibrado (FP32)** viene incluido. La recomendación se calcula con la memoria, el ahorro de energía y el estado térmico del dispositivo: puede sugerir **Nano compacto (FP16)** para consumir menos recursos. **FFDetr detallado (INT8)** aporta otra familia de detección. El selector manual permite elegir el modelo principal. **Multi IA** muestra el primer resultado disponible y lo contrasta con los otros modelos instalados. En Ajustes puedes instalar los tres; sus variantes y límites se explican en la propia pantalla.

La app obtiene el modelo y la memoria física del dispositivo y reduce los hilos de análisis en bajo consumo o con temperatura alta. **Medir modelos instalados** compara sus tiempos reales sobre el mismo ejemplo. No se presentan cifras de un ordenador como si fueran de un iPhone. [Investigación, licencias, métricas y adaptación para CPU móvil](Docs/Models.md).

Las descargas verifican tamaño y SHA-256 y ejecutan una inferencia real antes de habilitar el modelo. Puedes eliminarlas sin perder documentos. Solo las descargas requieren internet; el análisis de documentos sigue siendo local.

## Compilar y verificar

Requiere macOS, **Xcode 26.6 o posterior**, XcodeGen y Python 3.12 para preparar los modelos. GitHub Actions comprueba Xcode 26.6/iOS 26 y Xcode 27.0/iOS 27. La IPA publicada usa el SDK 27 y conserva iOS 26 como mínimo.

```sh
brew install xcodegen
mkdir -p Models
python3 -m venv .build-tools
.build-tools/bin/pip install onnx==1.23.2 numpy==2.3.5
.build-tools/bin/python Scripts/prepare_models.py
swift Scripts/GenerateIcon.swift
xcodegen generate
xcodebuild -project FormScan.xcodeproj -scheme FormScan -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Abre el proyecto generado en Xcode para ejecutar las pruebas en un simulador iOS 26. El workflow comprueba sincronización y borrado de anotaciones, campos PDF existentes, persistencia al volver a abrir, casillas y documentos con varias páginas, coordenadas y recortes, inferencia ONNX real y conservación de valores al repetir la detección. Las pruebas UI cubren pantalla completa, modos claro/oscuro, formulario, vista de documento, hoja de compartir y orientación horizontal; sus capturas se conservan en el artefacto `FormScan-build-and-verification-iOS26` y `FormScan-build-and-verification-iOS27` junto con el resultado de XCTest.

La cámara requiere un iPhone/iPad físico y no puede validarse mediante el simulador. La firma e instalación de SideStore también requieren el dispositivo.

## Publicación y versiones

Solo después de compilar y superar las pruebas, `main` publica `v<CFBundleShortVersionString>`. `Scripts/release_source.py` lee **Info.plist dentro de la IPA**, calcula su tamaño y genera las dos fuentes de SideStore. La descarga usa una URL de versión inmutable. No edites a mano versiones, tamaños ni URLs en las fuentes: cambia `MARKETING_VERSION` y `CURRENT_PROJECT_VERSION` en `project.yml` para una nueva publicación.

## Recursos

Modelo [nutrientdocs/form-field-v1-nano](https://huggingface.co/nutrientdocs/form-field-v1-nano), licencia Apache 2.0. Inferencia con ONNX Runtime 1.20.0 (MIT). El modelo detecta texto, opciones y firmas; los campos propuestos deben revisarse antes de compartir. Los iconos claro y oscuro originales se conservan en `Artwork/`; el catálogo recibe imágenes opacas de 1024 px. iOS aplica su apariencia tintada del sistema.


Guía aplicada para [iOS 27](Docs/iOS27.md), con compatibilidad con iOS 26. El análisis comienza al importar o escanear; Multi IA contrasta los modelos instalados y conserva las ediciones del usuario.
