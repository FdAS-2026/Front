#include <SPI.h>
#include <LoRa.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <Preferences.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// -------------------- PINOUT
const int LORA_MISO = 19;
const int LORA_SS   = 18;
const int LORA_SCK  = 5;
const int LORA_MOSI = 27;
const int LORA_RST  = 14;
const int LORA_IRQ  = 26;

const int OLED_SCL = 15;
const int OLED_SDA = 4;
const int OLED_RST = 16;

const long LORA_FREQ = 915E6;

#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64
Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RST);

Preferences prefs;

// -------------------- BLE UUIDs
#define SERVICE_UUID        "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_RX_UUID "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_TX_UUID "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

// -------------------- ESTADO GLOBAL
bool displayReady = false;
uint8_t NODE_ID = 0;
uint8_t PEER_ID = 0;

int BLE_clients_connected = 0;
BLEServer* pServer = NULL;
BLECharacteristic* pTxCharacteristic = NULL;

// Estructura para mensajes
struct Message {
  uint8_t from;
  String text;
  unsigned long timestamp;
  int rssi;
  bool isBLE;
};

const int MSG_BUFFER_SIZE = 10;
Message msgBuffer[MSG_BUFFER_SIZE];
int msgBufferIdx = 0;

// Latencia
unsigned long lastMsgSentTime = 0;
String lastMsgSent = "";
unsigned long lastAckReceivedTime = 0;
bool waitingForAck = false;

unsigned long lastHeartbeatTime = 0;
const unsigned long HEARTBEAT_MS = 5000;

// ==================== FORWARD DECLARATIONS ====================
void displayStatus();
void displayMessage(const String &t);
void sendMessage(uint8_t to, uint8_t from, uint8_t type, const String &msg);
void sendAck(uint8_t to, uint8_t from);
void addMessageToBuffer(uint8_t msgFrom, const String &text, unsigned long ts, int rssi, bool isBLE);

// ==================== BLE CALLBACKS ====================
class MyServerCallbacks: public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    BLE_clients_connected++;
    Serial.print("BLE: Cliente conectado. Total: "); Serial.println(BLE_clients_connected);
    displayStatus();
  };

  void onDisconnect(BLEServer* pServer) {
    if (BLE_clients_connected > 0) BLE_clients_connected--;
    Serial.print("BLE: Cliente desconectado. Total: "); Serial.println(BLE_clients_connected);
    displayStatus();
  }
};

class MyCharacteristicCallbacks: public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *pCharacteristic) {
    String rxValue = pCharacteristic->getValue().c_str();
    if (rxValue.length() > 0) {
      String msg = rxValue;
      msg.trim();
      if (msg.length() > 0) {
        Serial.print("BLE RX: "); Serial.println(msg);
        
        // Enviar por LoRa al peer
        sendMessage(PEER_ID, NODE_ID, 0, msg);
        lastMsgSent = msg;
        lastMsgSentTime = millis();
        waitingForAck = true;
        addMessageToBuffer(NODE_ID, msg, millis(), 0, true);
        displayStatus();
      }
    }
  }
};

// ==================== SETUP ====================
void setup() {
  Serial.begin(115200);
  delay(100);

  // OLED
  Wire.begin(OLED_SDA, OLED_SCL);
  if (!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) {
    displayReady = false;
  } else {
    displayReady = true;
  }
  display.clearDisplay();
  display.setTextSize(1);
  display.setTextColor(SSD1306_WHITE);

  // LoRa
  SPI.begin(LORA_SCK, LORA_MISO, LORA_MOSI, LORA_SS);
  LoRa.setPins(LORA_SS, LORA_RST, LORA_IRQ);
  if (!LoRa.begin(LORA_FREQ)) {
    Serial.println("LoRa init failed.");
    displayMessage("LoRa FAILED");
    while (1) { delay(2000); }
  }

  // Auto-discovery LoRa
  prefs.begin("lora", false);
  uint8_t storedNode = prefs.getUChar("node_id", 0);
  uint8_t storedPeer = prefs.getUChar("peer_id", 0);

  displayMessage("Auto-detecting...");
  Serial.println("--- P2P LoRa + BLE starting ---");

  unsigned long start = millis();
  bool discoveredPeer = false;
  uint8_t detectedPeerID = 0;
  
  while (millis() - start < 5000) {
    if (Serial.available()) {
      String s = Serial.readStringUntil('\n');
      s.trim();
      if (s.length() && s.indexOf("node=") >= 0) {
        int nIndex = s.indexOf("node=");
        int pIndex = s.indexOf("peer=");
        if (nIndex >= 0) {
          String nval = s.substring(nIndex + 5);
          if (nval.indexOf(' ')>0) nval = nval.substring(0, nval.indexOf(' '));
          NODE_ID = (uint8_t) nval.toInt();
        }
        if (pIndex >= 0) {
          String pval = s.substring(pIndex + 5);
          if (pval.indexOf(' ')>0) pval = pval.substring(0, pval.indexOf(' '));
          PEER_ID = (uint8_t) pval.toInt();
        }
        prefs.putUChar("node_id", NODE_ID);
        prefs.putUChar("peer_id", PEER_ID);
        goto ble_init;
      }
    }
    
    int packetSize = LoRa.parsePacket();
    if (packetSize) {
      uint8_t to = LoRa.read();
      uint8_t from = LoRa.read();
      LoRa.read();
      String payload = "";
      while (LoRa.available()) payload += (char)LoRa.read();
      
      detectedPeerID = from;
      discoveredPeer = true;
      break;
    }
    delay(50);
  }

  if (discoveredPeer) {
    PEER_ID = detectedPeerID;
    NODE_ID = (PEER_ID == 1) ? 2 : 1;
  } else if (storedNode != 0 && storedPeer != 0) {
    NODE_ID = storedNode;
    PEER_ID = storedPeer;
  } else {
    NODE_ID = 1;
    PEER_ID = 2;
  }

  prefs.putUChar("node_id", NODE_ID);
  prefs.putUChar("peer_id", PEER_ID);

  Serial.print("Node ID: "); Serial.println(NODE_ID);
  Serial.print("Peer ID: "); Serial.println(PEER_ID);

ble_init:
  // ==================== INICIALIZAR BLE ====================
  String deviceName = "LoRA_N" + String(NODE_ID);
  BLEDevice::init(deviceName.c_str());
  
  // Configurar poder y MTU
  BLEDevice::setPower(ESP_PWR_LVL_P7);
  
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  BLEService *pService = pServer->createService(SERVICE_UUID);

  // Característica TX (notificaciones al teléfono)
  pTxCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_TX_UUID,
    BLECharacteristic::PROPERTY_NOTIFY | BLECharacteristic::PROPERTY_READ
  );
  pTxCharacteristic->setAccessPermissions(ESP_GATT_PERM_READ);
  pTxCharacteristic->addDescriptor(new BLE2902());

  // Característica RX (recibir del teléfono)
  BLECharacteristic *pRxCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_RX_UUID,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR
  );
  pRxCharacteristic->setAccessPermissions(ESP_GATT_PERM_WRITE);
  pRxCharacteristic->setCallbacks(new MyCharacteristicCallbacks());

  pService->start();

  // Configurar advertising
  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06);
  pAdvertising->setMaxPreferred(0x12);
  
  BLEDevice::startAdvertising();

  // Configurar MTU
  BLEDevice::setMTU(185);

  Serial.print("BLE initialized: "); Serial.println(deviceName);
  Serial.println("Waiting for BLE connections...");
  displayStatus();
}

// ==================== LOOP ====================
void loop() {
  // Recibir LoRa
  int packetSize = LoRa.parsePacket();
  if (packetSize) {
    uint8_t to = LoRa.read();
    uint8_t from = LoRa.read();
    uint8_t type = LoRa.read();
    String payload = "";
    while (LoRa.available()) payload += (char)LoRa.read();
    
    int rssi = LoRa.packetRssi();
    unsigned long rxTime = millis();

    if (to == NODE_ID) {
      if (type == 1) {
        // ACK
        lastAckReceivedTime = rxTime;
        unsigned long latency = rxTime - lastMsgSentTime;
        Serial.print("ACK in: "); Serial.print(latency); Serial.println("ms");
        waitingForAck = false;
      } else {
        // Mensaje de datos
        Serial.print("RX LoRa from "); Serial.print(from);
        Serial.print(": "); Serial.println(payload);
        
        addMessageToBuffer(from, payload, rxTime, rssi, false);
        
        // Enviar por BLE a todos los clientes conectados
        if (BLE_clients_connected > 0 && pTxCharacteristic != NULL) {
          String bleTx = String(from) + ": " + payload;
          pTxCharacteristic->setValue((uint8_t *)bleTx.c_str(), bleTx.length());
          pTxCharacteristic->notify();
          Serial.print("BLE TX notify: "); Serial.println(bleTx);
        }
        
        // Responder ACK por LoRa
        sendAck(from, NODE_ID);
      }
      displayStatus();
    }
  }

  // Heartbeat
  if (millis() - lastHeartbeatTime > HEARTBEAT_MS && !waitingForAck) {
    lastHeartbeatTime = millis();
    String hb = "HB";
    sendMessage(PEER_ID, NODE_ID, 0, hb);
    lastMsgSent = hb;
    lastMsgSentTime = millis();
    waitingForAck = true;
  }

  delay(10);
}

// ==================== FUNCIONES ====================
void sendMessage(uint8_t to, uint8_t from, uint8_t type, const String &msg) {
  LoRa.beginPacket();
  LoRa.write(to);
  LoRa.write(from);
  LoRa.write(type);
  LoRa.print(msg.substring(0, 50));
  LoRa.endPacket();
}

void sendAck(uint8_t to, uint8_t from) {
  sendMessage(to, from, 1, "ACK");
}

void addMessageToBuffer(uint8_t msgFrom, const String &text, unsigned long ts, int rssi, bool isBLE) {
  msgBuffer[msgBufferIdx].from = msgFrom;
  msgBuffer[msgBufferIdx].text = text.substring(0, 20);
  msgBuffer[msgBufferIdx].timestamp = ts;
  msgBuffer[msgBufferIdx].rssi = rssi;
  msgBuffer[msgBufferIdx].isBLE = isBLE;
  msgBufferIdx = (msgBufferIdx + 1) % MSG_BUFFER_SIZE;
}

void displayMessage(const String &t) {
  if (!displayReady) return;
  display.clearDisplay();
  display.setCursor(0, 0);
  display.setTextSize(2);
  display.println(t);
  display.display();
}

void displayStatus() {
  if (!displayReady) return;
  display.clearDisplay();
  display.setTextSize(1);
  display.setCursor(0, 0);
  
  // Header
  display.print("N"); display.print(NODE_ID);
  display.print(" BLE:");
  if (BLE_clients_connected > 0) {
    display.print(BLE_clients_connected);
  } else {
    display.print("--");
  }
  display.print(" ");
  if (waitingForAck) {
    display.println("ACK..");
  } else {
    display.println("ok");
  }
  
  display.drawLine(0, 10, 128, 10, SSD1306_WHITE);
  
  // Mostrar últimos 4 mensajes
  int startIdx = (msgBufferIdx - 4 + MSG_BUFFER_SIZE) % MSG_BUFFER_SIZE;
  int line = 12;
  
  for (int i = 0; i < 4; i++) {
    int idx = (startIdx + i) % MSG_BUFFER_SIZE;
    if (msgBuffer[idx].from != 0) {
      display.setCursor(0, line);
      if (msgBuffer[idx].isBLE) {
        display.print("B");
      } else {
        display.print("L");
      }
      display.print((msgBuffer[idx].from == NODE_ID) ? ">" : "<");
      display.print(msgBuffer[idx].from);
      display.print(": ");
      display.println(msgBuffer[idx].text);
      line += 10;
    }
  }
  
  display.drawLine(0, 53, 128, 53, SSD1306_WHITE);
  display.setCursor(0, 55);
  display.print("RSSI: ");
  if (msgBuffer[(msgBufferIdx - 1 + MSG_BUFFER_SIZE) % MSG_BUFFER_SIZE].from != 0) {
    display.println(msgBuffer[(msgBufferIdx - 1 + MSG_BUFFER_SIZE) % MSG_BUFFER_SIZE].rssi);
  } else {
    display.println("--");
  }
  
  display.display();
}
