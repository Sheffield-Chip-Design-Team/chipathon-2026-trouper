// Heltec WiFi LoRa 32 V3 — multi-config LoRa TX for IQ sample collection
// Cycles through a table of SF / BW / preamble configurations, transmitting
// PKTS_PER_CONFIG packets on each before moving to the next.
// The payload encodes the config index so captures are self-labelling.
//
// Hardware: SX1262 pin mapping per Heltec V3 schematic
//   NSS=8  DIO1=14  RST=12  BUSY=13
//
// Library: RadioLib 7.x
// Board:   Heltec ESP32 (FQBN heltec:esp32:heltec_wifi_lora_32_V3)

#include <RadioLib.h>

// ---------- hardware pins ----------
#define LORA_NSS   8
#define LORA_DIO1  14
#define LORA_RST   12
#define LORA_BUSY  13

// ---------- fixed parameters (same for all configs) ----------
#define BASE_FREQ  868.1   // MHz — EU868 channel, adjust for your region
#define LORA_CR    5       // coding rate 4/5
#define LORA_POWER -9      // dBm — SX1262 hardware minimum; raise for range testing
#define TX_INTERVAL_MS 2000
#define PKTS_PER_CONFIG 20

// ---------- config table ----------
struct LoRaConfig {
  float bw;       // kHz  (7.8 / 10.4 / 15.6 / 20.8 / 31.25 / 41.7 / 62.5 / 125 / 250 / 500)
  uint8_t sf;     // 5–12
  uint16_t pre;   // preamble symbols (min 6; 8 = LoRaWAN default)
  const char *label;
};

static const LoRaConfig CONFIGS[] = {
  // BW=125 kHz — sweep spreading factors
  { 125.0,  7,  8, "SF7-BW125-Pre8"  },
  { 125.0,  9,  8, "SF9-BW125-Pre8"  },
  { 125.0, 12,  8, "SF12-BW125-Pre8" },

  // BW=125 kHz — sweep preamble lengths (SF7 baseline)
  { 125.0,  7,  6, "SF7-BW125-Pre6"  },
  { 125.0,  7, 12, "SF7-BW125-Pre12" },
  { 125.0,  7, 16, "SF7-BW125-Pre16" },

  // Wider bandwidths at SF7
  { 250.0,  7,  8, "SF7-BW250-Pre8"  },
  { 500.0,  7,  8, "SF7-BW500-Pre8"  },

  // High-SF wide-BW (unusual but interesting for ML datasets)
  { 500.0, 10,  8, "SF10-BW500-Pre8" },
};

static const uint8_t NUM_CONFIGS = sizeof(CONFIGS) / sizeof(CONFIGS[0]);

SX1262 radio = new Module(LORA_NSS, LORA_DIO1, LORA_RST, LORA_BUSY);

uint8_t cfgIdx = 0;
int     pktNum = 0;

// Apply the given config to the already-initialised radio.
static void applyConfig(const LoRaConfig &c) {
  radio.setFrequency(BASE_FREQ);
  radio.setBandwidth(c.bw);
  radio.setSpreadingFactor(c.sf);
  radio.setCodingRate(LORA_CR);
  radio.setPreambleLength(c.pre);
  radio.setOutputPower(LORA_POWER);

  Serial.printf("\n=== CONFIG %u/%u: %s ===\n", cfgIdx, NUM_CONFIGS - 1, c.label);
  Serial.printf("    %.1f MHz  SF%u  BW%.0f kHz  CR4/%u  Pre%u  %d dBm\n",
                BASE_FREQ, c.sf, c.bw, LORA_CR, c.pre, LORA_POWER);
  Serial.printf("    Sending %u packets, then advancing config.\n\n", PKTS_PER_CONFIG);
}

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println("LoRa multi-config TX — starting up");

  // Initialise with first config's parameters
  const LoRaConfig &first = CONFIGS[0];
  int state = radio.begin(BASE_FREQ, first.bw, first.sf, LORA_CR,
                          RADIOLIB_SX126X_SYNC_WORD_PRIVATE, LORA_POWER);
  if (state != RADIOLIB_ERR_NONE) {
    Serial.printf("Radio init failed: %d\n", state);
    while (true) delay(1000);
  }

  radio.setTCXO(1.8);
  radio.setDio2AsRfSwitch(true);
  radio.setPreambleLength(first.pre);

  Serial.println("Radio initialised OK.");
  applyConfig(CONFIGS[cfgIdx]);
}

void loop() {
  const LoRaConfig &c = CONFIGS[cfgIdx];

  // Payload: "C{config_idx}#{pkt_within_config} {label}"
  // e.g. "C0#3 SF7-BW125-Pre8"
  // This embeds the config identity in the over-the-air data.
  char payload[64];
  int  localPkt = pktNum % PKTS_PER_CONFIG;
  snprintf(payload, sizeof(payload), "C%u#%d %s", cfgIdx, localPkt, c.label);

  Serial.printf("TX [C%u #%d]: %s\n", cfgIdx, localPkt, payload);

  int state = radio.transmit(payload);
  if (state == RADIOLIB_ERR_NONE) {
    Serial.println("  OK");
  } else {
    Serial.printf("  TX error: %d\n", state);
  }

  pktNum++;

  // Advance to next config after PKTS_PER_CONFIG packets
  if (pktNum % PKTS_PER_CONFIG == 0) {
    cfgIdx = (cfgIdx + 1) % NUM_CONFIGS;
    applyConfig(CONFIGS[cfgIdx]);
  }

  delay(TX_INTERVAL_MS);
}
