# Timer Studio por red local

Candidato para pruebas de oficina. No es una entrega validada en la red física.

El ordenador que ya ejecuta Companion sirve Timer. Windows abre Timer en el navegador, sin instalar un ejecutable de Timer. El teléfono abre el mando escaneando el QR mostrado en Windows.

## Preparación

1. Conserva una copia de la configuración de Companion.
2. Importa el paquete candidato de Timer y crea una conexión para la prueba.
3. Selecciona «Timer en navegador por red local».
4. En Windows abre `http://IP-COMPANION:8000/instance/NOMBRE-CONEXION/index.html`. Sustituye la IP y el nombre de conexión exactos. Usa el puerto de Companion si es distinto de 8000; los espacios del nombre se escriben como `%20`.
5. Añade los botones de inicio, pausa, reset y 5/10/30 minutos desde Presets.
6. Pulsa «Control móvil» en Windows. Escanea con la cámara nativa del teléfono conectado a la misma red.

El QR se cierra al vincularse el mando y aparece su identificador. La vista extendida continúa disponible. Los recursos se sirven desde Companion, sin descargar la suite.

## Prueba de aceptación pendiente

Con Windows, Companion y el teléfono reales: comprueba los botones, QR, identificación del mando, avisos y segunda pantalla. Desconecta la salida a internet manteniendo switch y Wi-Fi locales; recarga Timer y el mando y repite el control durante diez minutos. Registra versiones, resultados y capturas.

Las pruebas automáticas de Windows usan el módulo empaquetado y el protocolo del SDK de Companion. El teléfono se simula en un navegador. Bloquean las peticiones externas del navegador. No sustituyen la importación manual en Companion, el firewall, el escaneo físico ni la prueba de red de oficina.

## Alcance

La aplicación de Mac y la suite no se han modificado. El candidato conserva la opción OSC para Timer instalado y reconoce las configuraciones antiguas. El ordenador de Companion debe permanecer encendido. Reiniciar el módulo reinicia el reloj; la agenda permanece guardada en el navegador.

Este paquete no firma ni corrige los antiguos ejecutables de Windows: utiliza otra vía de funcionamiento.
