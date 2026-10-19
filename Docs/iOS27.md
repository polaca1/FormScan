# Guía de FormScan para iOS 27

Aplicación de la documentación oficial de Apple; no implica certificación de Apple.

## Fuentes oficiales

- [Novedades de SwiftUI en WWDC26](https://developer.apple.com/wwdc26/guides/swiftui/).
- [Sesión de SwiftUI de WWDC26](https://developer.apple.com/videos/play/wwdc2026/269/).
- [Acciones ancladas al extremo de la barra](https://developer.apple.com/documentation/swiftui/toolbaritemplacement/topbarpinnedtrailing).
- [Cambios de geometría](https://developer.apple.com/documentation/swiftui/view/ongeometrychange(for:of:action:)).
- [HIG: barras de herramientas](https://developer.apple.com/design/human-interface-guidelines/toolbars), [materiales](https://developer.apple.com/design/human-interface-guidelines/materials) y [movimiento](https://developer.apple.com/design/human-interface-guidelines/motion).

## Reglas aplicadas

1. Compilar la entrega con el SDK de iOS 27 para recibir la apariencia nativa actualizada de SwiftUI. Mantener iOS 26 como versión mínima y compilar también la ruta compatible con Xcode 26.
2. En iOS 27 anclar Compartir mediante `topBarPinnedTrailing`. La acción pertenece al documento y mantiene su identidad al alternar Documento/Formulario. En iOS 26 usar `topBarTrailing` con separación nativa entre Compartir y Opciones.
3. Adaptar el editor al ancho real de su ventana. A partir de 820 puntos mostrar documento y formulario juntos; por debajo, selector de vistas. No inferir espacio suficiente solo por el tipo de dispositivo o su clase de tamaño.
4. Mantener PDFKit y formulario vivos al cambiar de vista; animar solo la opacidad del contenido. Respetar Reducir movimiento. No animar toda la barra ni reconstruir el PDF al cambiar el selector.
5. Conservar tres destinos claros: Inicio, Documentos y Ajustes. Usar TabView, NavigationStack, menús y hojas nativos. Reservar Liquid Glass para controles y navegación, con el documento sobre un lienzo legible.
6. El análisis automático no bloquea la lectura ni la escritura. Mostrar progreso y cancelación. Los resultados posteriores preservan los valores y campos que el usuario ya editó.

## Verificación

La entrega debe superar pruebas de PDF y modelos locales, importación real desde Archivos, persistencia, exportación y navegación en simulador. Las capturas adjuntas a la ejecución permiten revisar pantalla completa, modo claro/oscuro, textos grandes, orientación y alternancia entre vistas. La cámara física y la firma/instalación de SideStore requieren un iPhone real; no se consideran verificadas por una compilación de simulador.
