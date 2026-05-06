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
   - Selecciona uno de los dispositivos (LoRA_N1 o LoRA_N2)
   - Escribe mensajes y presiona "Enviar"
   - Los mensajes se transmiten por LoRa a la otra placa
   - Recibes respuestas en tiempo real

## Características

- ✅ Escaneo automático de dispositivos LoRa
- ✅ Conexión BLE con características de notificación
- ✅ Historial de mensajes en tiempo real
- ✅ Indicadores visuales de enviado (📤) / recibido (📨)
- ✅ Desconexión automática con reinicio
- ✅ UI responsive y amigable

## Estructura

```
flutter_app/
├── pubspec.yaml          # Dependencias
├── lib/
│   └── main.dart         # Código principal (única pantalla)
└── README.md             # Este archivo
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
