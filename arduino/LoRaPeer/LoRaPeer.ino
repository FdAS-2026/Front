#include <SPI.h>
#include <LoRa.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <Preferences.h>

// -------------------- PINOUT (según indicaciones)
const int LORA_MISO = 19;
const int LORA_SS   = 18; // CS
const int LORA_SCK  = 5;
const int LORA_MOSI = 27;
const int LORA_RST  = 14;
const int LORA_IRQ  = 26; // DIO0

const int OLED_SCL = 15;
const int OLED_SDA = 4;
const int OLED_RST = 16;

// -------------------- LoRa / display config
const long LORA_FREQ = 915E6; // ajustar a 868E6 o 433E6 según tu región

#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64
Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RST);

Preferences prefs;

bool displayReady = false;
uint8_t NODE_ID = 0;
uint8_t PEER_ID = 0;

// Estructura para mensajes con timestamp
struct Message {
  uint8_t from;
  String text;
  unsigned long timestamp;
  int rssi;
};

// Buffer de conversación (últimos 10 mensajes)
const int MSG_BUFFER_SIZE = 10;
Message msgBuffer[MSG_BUFFER_SIZE];
int msgBufferIdx = 0;

// Para medir latencia
unsigned long lastMsgSentTime = 0;
String lastMsgSent = "";
unsigned long lastAckReceivedTime = 0;
bool waitingForAck = false;

unsigned long lastHeartbeatTime = 0;
const unsigned long HEARTBEAT_MS = 5000;

void setup() {
  Serial.begin(115200);
  delay(100);

  // I2C para OLED con los pines proporcionados
  Wire.begin(OLED_SDA, OLED_SCL);
  if (!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) {
    Serial.println("SSD1306 allocation failed");
    displayReady = false;
  } else {
    displayReady = true;
  }
  display.clearDisplay();
  display.setTextSize(1);
  display.setTextColor(SSD1306_WHITE);

  // SPI custom pins para SX1276/78
  SPI.begin(LORA_SCK, LORA_MISO, LORA_MOSI, LORA_SS);
  LoRa.setPins(LORA_SS, LORA_RST, LORA_IRQ);
  if (!LoRa.begin(LORA_FREQ)) {
    Serial.println("LoRa init failed. Check wiring and frequency.");
    displayMessage("LoRa init FAILED");
    while (1) { delay(2000); }
  }

  // Preferences (NVS) para guardar IDs y evitar reconfigurar cada vez
  prefs.begin("lora", false);
  uint8_t storedNode = prefs.getUChar("node_id", 0);
  uint8_t storedPeer = prefs.getUChar("peer_id", 0);

  displayMessage("Auto-detecting...");
  Serial.println("--- LoRaPeer starting ---");
  Serial.println("Escuchando red LoRa por 5s para auto-configurarse...");

  // Auto-discovery: escuchar paquetes en los próximos 5 segundos
  unsigned long start = millis();
  bool discoveredPeer = false;
  uint8_t detectedPeerID = 0;
  
  while (millis() - start < 5000) {
    if (Serial.available()) {
      String s = Serial.readStringUntil('\n');
      s.trim();
      if (s.length()) {
        Serial.println("Entrada por Serial detectada: " + s);
        // Formato esperado: node=<n> peer=<m>
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
        Serial.println("IDs configurados manualmente.");
        prefs.putUChar("node_id", NODE_ID);
        prefs.putUChar("peer_id", PEER_ID);
        return; // salir del setup después de configurar
      }
    }
    
    // Escuchar paquetes LoRa para auto-detección
    int packetSize = LoRa.parsePacket();
    if (packetSize) {
      uint8_t to = LoRa.read();
      uint8_t from = LoRa.read();
      LoRa.read(); // seq
      String payload = "";
      while (LoRa.available()) payload += (char)LoRa.read();
      
      Serial.print("Detectado paquete de node "); Serial.println(from);
      detectedPeerID = from;
      discoveredPeer = true;
      break;
    }
    delay(50);
  }

  // Si detectó un peer, usar el ID opuesto
  if (discoveredPeer) {
    PEER_ID = detectedPeerID;
    NODE_ID = (PEER_ID == 1) ? 2 : 1;
    Serial.print("Auto-configured: NODE_ID="); Serial.print(NODE_ID);
    Serial.print(" PEER_ID="); Serial.println(PEER_ID);
  } else if (storedNode != 0 && storedPeer != 0) {
    // Usar valores guardados si los hay
    NODE_ID = storedNode;
    PEER_ID = storedPeer;
    Serial.print("Usando IDs guardados: NODE_ID="); Serial.print(NODE_ID);
    Serial.print(" PEER_ID="); Serial.println(PEER_ID);
  } else {
    // Defaults: esta es probablemente la primera placa
    NODE_ID = 1;
    PEER_ID = 2;
    Serial.println("Usando IDs por defecto: NODE_ID=1 PEER_ID=2");
  }

  // Guardar
  prefs.putUChar("node_id", NODE_ID);
  prefs.putUChar("peer_id", PEER_ID);

  Serial.print("Node ID: "); Serial.println(NODE_ID);
  Serial.print("Peer ID: "); Serial.println(PEER_ID);
  Serial.println("Comandos: 'msg: tu mensaje aqui' para enviar");
  displayStatus();
}

void loop() {
  // Recibir paquetes
  int packetSize = LoRa.parsePacket();
  if (packetSize) {
    uint8_t to = LoRa.read();
    uint8_t from = LoRa.read();
    uint8_t type = LoRa.read(); // tipo: 0=msg, 1=ACK
    String payload = "";
    while (LoRa.available()) payload += (char)LoRa.read();
    
    int rssi = LoRa.packetRssi();
    unsigned long rxTime = millis();

    if (to == NODE_ID) {
      if (type == 1) {
        // ACK recibido
        lastAckReceivedTime = rxTime;
        unsigned long latency = rxTime - lastMsgSentTime;
        Serial.print("ACK recibido en: "); Serial.print(latency); Serial.println("ms");
        waitingForAck = false;
      } else {
        // Mensaje de datos
        Serial.print("RX from "); Serial.print(from);
        Serial.print(" -> "); Serial.print(payload);
        Serial.print(" [rssi="); Serial.print(rssi); Serial.println("]");
        
        // Guardar en buffer y mostrar en OLED
        addMessageToBuffer(from, payload, rxTime, rssi);
        
        // Enviar ACK
        sendAck(from, NODE_ID);
      }
      displayStatus();
    }
  }

  // Envío periódico heartbeat (solo si no estamos esperando ACK)
  if (millis() - lastHeartbeatTime > HEARTBEAT_MS && !waitingForAck) {
    lastHeartbeatTime = millis();
    String hb = "HB";
    sendMessage(PEER_ID, NODE_ID, 0, hb);
    lastMsgSent = hb;
    lastMsgSentTime = millis();
    waitingForAck = true;
  }

  // Leer comandos por Serial
  if (Serial.available()) {
    String line = Serial.readStringUntil('\n');
    line.trim();
    
    if (line.startsWith("msg:")) {
      String msg = line.substring(4);
      msg.trim();
      if (msg.length() > 0) {
        sendMessage(PEER_ID, NODE_ID, 0, msg);
        lastMsgSent = msg;
        lastMsgSentTime = millis();
        waitingForAck = true;
        addMessageToBuffer(NODE_ID, msg, millis(), 0);
        Serial.print("Sent: "); Serial.println(msg);
      }
    }
  }

  delay(10);
}

void sendMessage(uint8_t to, uint8_t from, uint8_t type, const String &msg) {
  LoRa.beginPacket();
  LoRa.write(to);
  LoRa.write(from);
  LoRa.write(type);  // 0=data, 1=ACK
  LoRa.print(msg);
  LoRa.endPacket();
}

void sendAck(uint8_t to, uint8_t from) {
  sendMessage(to, from, 1, "ACK");
}

void addMessageToBuffer(uint8_t msgFrom, const String &text, unsigned long ts, int rssi) {
  msgBuffer[msgBufferIdx].from = msgFrom;
  msgBuffer[msgBufferIdx].text = text.substring(0, 20);
  msgBuffer[msgBufferIdx].timestamp = ts;
  msgBuffer[msgBufferIdx].rssi = rssi;
  msgBufferIdx = (msgBufferIdx + 1) % MSG_BUFFER_SIZE;
}

void displayMessage(const String &t) {
  if (!displayReady) return;
  display.clearDisplay();
  display.setCursor(0,0);
  display.setTextSize(2);
  display.println(t);
  display.display();
}

void displayStatus() {
  if (!displayReady) return;
  display.clearDisplay();
  display.setTextSize(1);
  display.setCursor(0, 0);
  
  // Header: Node info
  display.print("N"); display.print(NODE_ID);
  display.print("/P"); display.print(PEER_ID);
  display.print(" ");
  if (waitingForAck) {
    display.println("(waiting ACK)");
  } else {
    display.println("(ready)");
  }
  
  // Línea separadora
  display.drawLine(0, 10, 128, 10, SSD1306_WHITE);
  
  // Mostrar últimos 4 mensajes
  int startIdx = (msgBufferIdx - 4 + MSG_BUFFER_SIZE) % MSG_BUFFER_SIZE;
  int line = 12;
  
  for (int i = 0; i < 4; i++) {
    int idx = (startIdx + i) % MSG_BUFFER_SIZE;
    if (msgBuffer[idx].from != 0) {
      display.setCursor(0, line);
      display.print((msgBuffer[idx].from == NODE_ID) ? ">" : "<");
      display.print(msgBuffer[idx].from);
      display.print(": ");
      display.println(msgBuffer[idx].text);
      line += 10;
    }
  }
  
  // Footer: señal
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
