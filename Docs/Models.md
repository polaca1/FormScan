# Modelos locales de FormScan

La recomendación para el iPhone 14 Pro (A16 Bionic) es **Nano FP32** como equilibrio para uso diario. Es una recomendación basada en tamaño, arquitectura y resultados publicados, no un benchmark realizado en un iPhone 14 Pro físico. La pantalla de modelos permite medir los tiempos en el dispositivo del usuario con el mismo formulario y elegir manualmente.

| Modelo | Tamaño | Uso y límites |
| --- | --- | --- |
| Nano FP32 | 3.73 MB | Incluido. Buen equilibrio y resultados publicados superiores a FFDetr en formularios escritos. mAP global publicado: 0.4792. |
| Nano FP16 | 1.92 MB | Descarga opcional. Ahorra almacenamiento; mAP global publicado: 0.4776. Su autor no atribuye una mejora de velocidad en CPU. |
| FFDetr INT8 | 37.12 MB | Descarga opcional para explorar otra arquitectura en formularios vacíos. Mayor consumo de memoria y tiempo. El FFDetr original obtiene mejores resultados en formularios vacíos, pero peores en escritos; no se atribuye al INT8 una precisión idéntica al original sin medirla. |

## Fuentes

- [Especificaciones del iPhone 14 Pro — Apple](https://support.apple.com/es-es/111849): A16 Bionic. La app obtiene memoria física y modelo del propio dispositivo; no infiere capacidad de ejecución a partir del nombre comercial.
- [Nano — Nutrient](https://huggingface.co/nutrientdocs/form-field-v1-nano), Apache-2.0, revisión `7cbc1ecd55d59f6315a1415dddc59c3c8b115f05`. Arquitectura YOLOX, RGB 0–255, letterbox superior izquierdo, entrada 640×640 y tres clases: texto, opción y firma.
- [FFDetr — James Barrow](https://huggingface.co/jbarrow/FFDetr), Apache-2.0, revisión `56f4e4235e28dcb2953513dc020bb191a2f54cfe`. RF-DETR Medium sobre CommonForms. [CommonForms](https://github.com/jbarrow/commonforms).
- [Exportación INT8 — Frooodle / Stirling PDF](https://huggingface.co/Frooodle/ffdetr-int8), revisión `ad3223d7c3ae25ce1d1ec8fe972c8ff7630aff45`. RGB, normalización ImageNet, redimensionado a 1024×1024; salidas `dets` y `labels`. [Script del exportador](https://github.com/Stirling-Tools/Stirling-PDF/blob/main/scripts/export-ffdetr-onnx.py).
- Los pesos de [Nutrient Small](https://huggingface.co/nutrientdocs/form-field-v1-small) y [Medium](https://huggingface.co/nutrientdocs/form-field-v1-medium) requieren licencia comercial y no están disponibles para descarga pública. No se ofrecen como instalables en FormScan.

## Compatibilidad y verificación

`prepare_models.py` verifica SHA-256 de todos los archivos. En FFDetr transforma únicamente los pesos y puntos cero de convolución de int8 a uint8 desplazando ambos +128. La resta y la convolución entera permanecen iguales. Esto permite usar el kernel CPU uint8/uint8 de ONNX Runtime 1.20; el archivo original usa un kernel de convolución firmado que ese runtime no implementa en todas las plataformas. No se alteran escalas ni se vuelve a entrenar el modelo. Se eliminan los inicializadores que dejan de usarse.

La adaptación es una modificación de FormScan. Se conservan autoría, licencia y fuentes originales; el archivo adaptado se publica por versión con SHA-256 `83adb3b1b6ed8ebe584c9046725913b541daccd9aee6d7bd18a00bbdebe6e33e`.

La aplicación verifica tamaño y SHA-256 y ejecuta una inferencia real antes de habilitar un modelo descargado. Una descarga cancelada, incompleta o incompatible conserva el modelo anterior. Los modelos alternativos no aumentan el tamaño de la IPA y pueden eliminarse sin perder documentos. Instalar modelos requiere internet; analizar documentos no envía datos a internet.

Modelos Nano y FFDetr: [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0). ONNX Runtime: [MIT](https://github.com/microsoft/onnxruntime/blob/main/LICENSE). Atribución adicional: James Barrow / CommonForms, Roboflow RF-DETR y Frooodle / Stirling PDF para la exportación original INT8. Las métricas publicadas en diferentes conjuntos de datos no son directamente comparables.


## Recomendación por dispositivo y Multi IA

La selección automática lee el identificador del dispositivo, la memoria física, Ahorro de energía y el estado térmico reales. Por debajo de 5 GiB o con ahorro/temperatura alta recomienda Nano FP16 (si falta, usa FP32 incluido) y ejecuta un modelo cada vez. Con 5–8 GiB recomienda FP32 y limita a dos inferencias simultáneas; con al menos 8 GiB permite tres. Es una política conservadora de recursos, no un benchmark de precisión del hardware. El selector manual siempre está disponible y se pueden medir los tiempos en el propio dispositivo.

Multi IA usa los tres modelos cuando están instalados; si falta alguno, usa los disponibles sin exigir conexión ni descargar pesos silenciosamente. El botón de instalación conjunta descarga y verifica los dos opcionales. Publica cada resultado conforme termina, contrasta por familias y refina la geometría cuando coinciden Nano y FFDetr. FP32 y FP16 son variantes correlacionadas de Nano y cuentan como una familia. Las puntuaciones de modelos distintos no están calibradas entre sí: no se promete que el último resultado sea objetivamente más preciso. Se preservan los resultados de una sola familia, los campos anteriores y cualquier edición que se haga durante el análisis.
