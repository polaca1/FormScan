# Diseño de FormScan según las guías oficiales de Apple

Revisión aplicada a FormScan 2.1.0. Estas son decisiones de implementación basadas en la documentación de Apple, no una certificación de Apple.

| Pauta oficial | Aplicación en FormScan |
| --- | --- |
| Las pestañas navegan entre secciones principales y conservan el contexto. | Inicio, Documentos y Ajustes tienen contenedores de navegación independientes. Se elimina el menú hamburguesa y la repetición de los mismos destinos en Inicio. |
| Mantener las pestañas disponibles; una tarea modal puede cubrirlas temporalmente. | Editar es una tarea a pantalla completa con Cerrar. Al terminar vuelve a la biblioteca, con las tres pestañas disponibles. |
| Limitar acciones en las barras y agruparlas según su función. | Compartir y Opciones usan elementos estándar y ToolbarSpacer; su geometría no depende del modo Documento/Formulario. Detectar y Añadir están en la barra de edición. |
| Usar Liquid Glass con moderación en controles y navegación, sin decoraciones en el contenido. | TabView, toolbars, picker, menús y botones nativos. Fondos semánticos, documentos sin tarjetas de cristal y sin tintado global forzado en las barras. |
| Movimiento breve, funcional y opcional. | Cambio de contenido de 0,2 segundos, sin recrear PDFKit ni animar la estructura de las barras. Se respeta Reducir movimiento; el selector conserva la interacción nativa. |
| Priorizar el contenido y títulos útiles. | Inicio contiene solo captura, importación y ejemplo; Documentos contiene la biblioteca; Ajustes contiene modelos y ayuda. Se usa Inicio como título del destino. |

Fuentes consultadas:

- [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)
- [Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars)
- [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)
- [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Motion](https://developer.apple.com/design/human-interface-guidelines/motion)
- [Build a SwiftUI app with the new design — WWDC25](https://developer.apple.com/videos/play/wwdc2025/323/)

La revisión de interfaz incluye claro/oscuro, orientación horizontal, texto de accesibilidad, cambios repetidos de modo con geometría estable y capturas del archivo realmente importado desde el selector del sistema. Una captura estática no mide los fps de un iPhone físico.
