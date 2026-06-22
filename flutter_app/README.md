# LoRa BLE Chat - Flutter App

App Flutter simple para comunicación P2P entre dos placas LoRa (ESP32 + SX1276/78) a través de BLE.

## Requisitos

- Flutter 3.0+
- Android (los permisos BLE están configurados)
- iOS (puede requerir ajustes adicionales en `ios/Podfile`)

## Instalación

1. **Clona o entra en el directorio de la app:**
```bash
cd flutter_app
```

2. **Instala dependencias:**
```bash
flutter pub get
```

3. **Asegúrate de que el SDK de Flutter está actualizado:**
```bash
flutter upgrade
```

## Permisos (Android)

Los permisos se solicitan automáticamente en runtime. La app necesita:
- `BLUETOOTH_SCAN`
- `BLUETOOTH_CONNECT`
- `ACCESS_FINE_LOCATION`

Android 12+ mostrará un prompt de permisos al iniciar la app.

## Uso

1. **Sube `LoRaPeer.ino` a ambas placas ESP32**
   - Node 1 y Node 2 se auto-detectan
   - Ambas exponen servidor BLE "LoRA_N1" y "LoRA_N2"

2. **Inicia la app:**
```bash
flutter run
```

3. **En la app:**
   - Presiona "Escanear" para buscar dispositivos LoRa
   - Conecta uno o varios nodos (LoRA_N1, LoRA_N2, ...) al mismo tiempo
   - Usa el botón flotante "Dispositivo" para agregar más sin perder los activos
   - Cambia de conversación con el selector de chips superior
   - Escribe mensajes y presiona "Enviar"; van al dispositivo activo

## Multi-dispositivo

La app mantiene **varias conexiones BLE simultáneas**. Cada nodo tiene su propio
hilo de mensajes y se elige el activo desde el selector superior. El panel de
estado muestra cuántos dispositivos hay conectados.

## Modo seguro (Huffman + RSA)

Acopla la funcionalidad nueva del firmware en la recepción. Desde el ícono de
candado en la barra superior se activa el "modo seguro" y se configura la clave
privada `(d, n)`. Al recibir un mensaje, la app:

1. Si el payload viene en hexadecimal, lo **descifra** con RSA (solo con la
   clave privada correcta).
2. Si el resultado es un buffer **Huffman**, lo descomprime.
3. Cae a texto plano si no aplica.

Los mensajes descifrados/descomprimidos muestran etiquetas en el chat. El codec
Dart (`lib/codec/`) es compatible byte a byte con el del firmware, verificado
con vectores de interoperabilidad en las pruebas.

## Características

- ✅ Múltiples dispositivos LoRa conectados en simultáneo + selector
- ✅ Escaneo automático de dispositivos LoRa
- ✅ Conexión BLE con características de notificación
- ✅ Historial de mensajes en tiempo real por dispositivo
- ✅ Descifrado RSA y descompresión Huffman en la app (modo seguro)
- ✅ UI responsive y amigable

## Estructura

```
flutter_app/
├── pubspec.yaml          # Dependencias
├── lib/
│   ├── main.dart         # App multi-dispositivo (UI + gestión BLE)
│   └── codec/
│       ├── huffman_codec.dart  # Huffman (espejo del firmware)
│       ├── rsa_cipher.dart     # RSA (espejo del firmware)
│       └── secure_codec.dart   # Pipeline de recepción hex→RSA→Huffman
├── test/                 # Pruebas unitarias (codec, cripto, pipeline, widget)
└── README.md             # Este archivo
```

## Pruebas

```bash
flutter test
```

## Solución de problemas

| Problema | Solución |
|----------|----------|
| "No se encontraron dispositivos" | Verifica que las placas estén encendidas y BLE inicializado |
| "Conexión fallida" | Intenta presionar "Desconectar" en las OLEDs de ambas placas y reinicia |
| Bluetooth no disponible | Asegúrate de haber dado permisos de BLE a la app |
| Mensajes no se reciben | Verifica que ambas placas están en rango (máx 100m) |

## Build APK (opcional)

```bash
flutter build apk --release
# El APK estará en: build/app/outputs/flutter-apk/app-release.apk
```

## Notas

- La app está optimizada para Android
- iOS requiere configuración adicional en Xcode
- Los UUIDs BLE deben coincidir con los del sketch Arduino
