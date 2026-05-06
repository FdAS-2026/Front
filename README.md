Prueba P2P LoRa entre dos placas ESP32 + SX1276/SX1278

Resumen
- Objetivo: probar comunicación P2P entre dos placas LoRa (ESP32 + SX1276/78).
- Entregables: dos sketches Arduino (`NodeA.ino` y `NodeB.ino`) y pasos de conexión y prueba.

Archivos añadidos
- `arduino/NodeA/NodeA.ino` — envío periódico y espera de ACK.
- `arduino/NodeB/NodeB.ino` — recepción y envío de ACK.

Librerías requeridas
- Instalar desde Library Manager: "LoRa" por Sandeep Mistry.

Configuración / Wiring (general)
- Conectar SPI del SX1276 al ESP32:
  - NSS (CS)  -> pin definido en `SS_PIN` (por defecto 18)
  - SCK      -> GPIO18 (si tu placa usa otro, ajústalo)
  - MISO     -> GPIO19
  - MOSI     -> GPIO23
  - RST      -> `RST_PIN` (por defecto 14)
  - DIO0     -> `DIO0_PIN` (por defecto 26)
  - VCC      -> 3.3V
  - GND      -> GND

Nota: algunos módulos usan otros pines por defecto. Revisa la serigrafía de tu placa y ajusta `SS_PIN`, `RST_PIN`, `DIO0_PIN` en los sketches si es necesario.

Frecuencia
- Cambia la constante `LORA_FREQ` en ambos sketches según tu región:
  - 915E6 -> 915 MHz (Américas)
  - 868E6 -> 868 MHz (Europa)
  - 433E6 -> 433 MHz (si tu módulo y licencia lo permiten)

Cómo probar
1. Abre Arduino IDE o VS Code + PlatformIO y selecciona la placa ESP32 correspondiente.
2. Instala la librería "LoRa" (Sandeep Mistry).
3. Sube `NodeA.ino` a la placa que será el emisor (ID 1) y `NodeB.ino` a la otra (ID 2).
4. Abre el Monitor Serial para ambas placas a 115200 baudios.
5. Alimenta ambas placas. NodeA enviará un mensaje cada 5s y esperará ACK. NodeB imprimirá los mensajes recibidos y responderá ACK.
6. Opcional: escribe texto en el Monitor Serial de cualquiera de las placas para enviar mensajes manuales.

Próximo paso
- Si la prueba P2P funciona, integramos la transmisión hacia un teléfono (por ejemplo: ESP32 puede exponer via BLE o Wi‑Fi un puente que reciba los mensajes LoRa y los forwardee al móvil). ¿Prefieres BLE o Wi‑Fi para la app móvil?
