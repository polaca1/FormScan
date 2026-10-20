# Tablas de formulario

FormScan 2.2.4 reconoce tablas impresas con bordes horizontales y verticales y contexto de fila y columna. La tabla de la captura «The environment» contiene seis problemas y tres columnas de respuesta: **18 campos**. El PDF original todavía no se ha recibido para comprobar este caso directamente.

La estructura se comprueba en la imagen original de cada página, antes de combinar las predicciones de los modelos. Cada celda necesita cuatro bordes impresos; una predicción de otra fila debajo de la tabla no crea una celda. El OCR de la fila y del encabezado se conserva en la etiqueta, por ejemplo: «insufficient water supply · Possible causes». Los textos se toman del documento; la aplicación no genera respuestas ni añade valores que no estén escritos.

Las celdas que ya contienen texto permanecen en el documento original y no se presentan como huecos vacíos. Las casillas con un contorno pequeño impreso dentro de una celda conservan su tipo de control. Los campos de texto y las casillas fuera de la tabla siguen usando la detección local. Las respuestas del usuario conservan su identidad, posición y valor al repetir el análisis, guardar, reabrir o exportar el PDF. Al abrir documentos analizados con versiones anteriores se actualiza el análisis y se reparan las predicciones vacías reconocibles; se conservan valores, campos manuales, widgets nativos y etiquetas personalizadas.

Esta versión comprueba cuadrículas rectas, cerradas y legibles. No deduce filas ocultas, respuestas, líneas rotas ni la estructura de tablas sin bordes. Fotografías torcidas o con poco contraste pueden necesitar recorte y un nuevo escaneo. El OCR puede equivocarse: las etiquetas siguen siendo editables.

La regresión de 21 campos amplía la reproducción a proporciones de papel carta apaisado, filas numeradas, líneas grises de 0,2 puntos y trazos inferiores sin etiqueta. Se comprueban las tres clases de predicción (texto, casilla y firma), cajas ligeramente desbordadas y resultados progresivos de los tres modelos reales. Los campos de firma o casilla ya no pueden saltarse la comprobación de continuidad. Un control independiente con contorno o subrayado y etiqueta impresos se conserva.

El análisis tiene versión propia (3): al abrir un documento procesado por la versión anterior se vuelve a comprobar automáticamente, también cuando ya contiene campos guardados de tabla. La prueba de actualización parte de 21 detecciones y conserva respuestas, etiquetas personalizadas y campos manuales.

La verificación incluye una reproducción sintética del diseño comunicado, OCR real, modelo ONNX real, límites abiertos, celdas ya escritas, ambos tipos de control, reparación de 24 predicciones antiguas, coordenadas rotadas, persistencia, exportación y edición desde la interfaz. No se ha recibido el PDF original para comprobarlo píxel por píxel.
