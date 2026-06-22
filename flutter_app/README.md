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

## Enlace y emparejamiento

Desde el ícono de cadena (🔗) en la barra superior:

- **Enlazar placa activa:** crea el bonding BLE (`createBond`). La placa muestra
  un PIN de 6 dígitos en su OLED y el sistema lo pide en el teléfono. La placa
  enlazada se recuerda entre sesiones (`shared_preferences`).
- **Desenlazar placa activa:** envía `UNLINK`, quita el bond (`removeBond`) y la
  olvida.
- **Emparejar placas (PIN):** ingresás un PIN y la app envía `PAIR:<pin>` a todas
  las placas conectadas; las que compartan el PIN quedan emparejadas entre sí por
  LoRa. La placa avisa con `PAIRED:Nx`.
- **Desemparejar placa activa:** envía `UNPAIR`.

Los chips del selector muestran 🔒 (enlazada) y 🔌 (emparejada). El modelo de
persistencia (`LinkedBoardsStore`) está cubierto por pruebas.

## Modo seguro (RSA-2048 + Huffman)

Acopla la funcionalidad del firmware en la recepción. Desde el ícono de candado
en la barra superior se activa el "modo seguro" y se pega la **clave privada en
formato PEM**. Al recibir un mensaje, la app:

1. Si el payload viene en base64, lo **descifra** con **RSA-2048 OAEP (SHA-256)**
   usando la clave privada (pointycastle). Solo la clave correcta descifra.
2. Si el resultado es un buffer **Huffman**, lo descomprime.
3. Cae a texto plano si no aplica.

Los mensajes descifrados/descomprimidos muestran etiquetas en el chat.

**Producción:** una clave privada no debería distribuirse dentro de la app. Las
claves de demo viven en `lib/codec/demo_keys.dart` con su advertencia; en
producción cargá la privada desde un secret store o `--dart-define`. El esquema
(RSA-2048 OAEP-SHA256, base64) es estándar y se verifica en las pruebas contra un
vector generado con OpenSSL, equivalente al que produce mbedtls en la placa.

## Características

- ✅ Múltiples dispositivos LoRa conectados en simultáneo + selector
- ✅ Escaneo automático de dispositivos LoRa
- ✅ Conexión BLE con características de notificación
- ✅ Historial de mensajes en tiempo real por dispositivo
- ✅ Descifrado RSA-2048 OAEP y descompresión Huffman en la app (modo seguro)
- ✅ UI responsive y amigable

## Estructura

```
flutter_app/
├── pubspec.yaml          # Dependencias
├── lib/
│   ├── main.dart         # App multi-dispositivo (UI + gestión BLE)
│   └── codec/
│       ├── huffman_codec.dart  # Huffman (espejo del firmware)
│       ├── rsa_oaep.dart       # RSA-2048 OAEP-SHA256 (pointycastle)
│       ├── demo_keys.dart      # Claves PEM de demostración
│       └── secure_codec.dart   # Pipeline de recepción base64→RSA→Huffman
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
