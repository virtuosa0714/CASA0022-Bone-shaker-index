#include <lvgl.h>
#include "Arduino_GFX_Library.h"
#include "pin_config.h"
#include "lv_conf.h"
#include <Arduino.h>
#include <Wire.h>
#include "SensorQMI8658.hpp"

// --- 电源管理库 ---
#include "XPowersLib.h" 

// --- 蓝牙相关头文件 ---
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

#define EXAMPLE_LVGL_TICK_PERIOD_MS 2

// --- 蓝牙配置 UUID ---
#define SERVICE_UUID           "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_TX "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

BLEServer *pServer = NULL;
BLECharacteristic *pTxCharacteristic;
bool deviceConnected = false;

// 蓝牙连接状态回调
class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) {
      deviceConnected = true;
    };
    void onDisconnect(BLEServer* pServer) {
      deviceConnected = false;
      pServer->getAdvertising()->start();
    }
};

static lv_disp_draw_buf_t draw_buf;
static lv_color_t buf[LCD_WIDTH * LCD_HEIGHT / 10];
SensorQMI8658 qmi;
IMUdata acc;

// --- 电源管理与电量显示对象 ---
XPowersPMU power;
lv_obj_t *label_battery; 
lv_obj_t *label;

Arduino_DataBus *bus = new Arduino_ESP32QSPI(
  LCD_CS, LCD_SCLK, LCD_SDIO0, LCD_SDIO1, LCD_SDIO2, LCD_SDIO3);
Arduino_CO5300 *gfx = new Arduino_CO5300(
  bus, LCD_RESET, 0, LCD_WIDTH, LCD_HEIGHT, 6, 0, 0, 0);

void my_disp_flush(lv_disp_drv_t *disp, const lv_area_t *area, lv_color_t *color_p) {
  uint32_t w = (area->x2 - area->x1 + 1);
  uint32_t h = (area->y2 - area->y1 + 1);
#if (LV_COLOR_16_SWAP != 0)
  gfx->draw16bitBeRGBBitmap(area->x1, area->y1, (uint16_t *)&color_p->full, w, h);
#else
  gfx->draw16bitRGBBitmap(area->x1, area->y1, (uint16_t *)&color_p->full, w, h);
#endif
  lv_disp_flush_ready(disp);
}

void example_increase_lvgl_tick(void *arg) {
  lv_tick_inc(EXAMPLE_LVGL_TICK_PERIOD_MS);
}

void setup() {
  Serial.begin(115200);
  Wire.begin(IIC_SDA, IIC_SCL);

  // --- 电源管理芯片初始化 ---
  if(power.begin(Wire, AXP2101_SLAVE_ADDRESS, IIC_SDA, IIC_SCL)) {
    power.clearIrqStatus();
    power.enableBattVoltageMeasure();
    power.enableVbusVoltageMeasure(); 
  } else {
    Serial.println("PMU Init Failed!");
  }

  gfx->begin();
  gfx->setBrightness(200);

  // --- 蓝牙初始化 ---
  BLEDevice::init("ESP32_S3_IMU");
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  BLEService *pService = pServer->createService(SERVICE_UUID);
  pTxCharacteristic = pService->createCharacteristic(
                        CHARACTERISTIC_UUID_TX,
                        BLECharacteristic::PROPERTY_NOTIFY
                      );
  pTxCharacteristic->addDescriptor(new BLE2902());
  pService->start();
  pServer->getAdvertising()->start();
  Serial.println("BLE Ready!");

  // --- LVGL 初始化 ---
  lv_init();
  lv_disp_draw_buf_init(&draw_buf, buf, NULL, LCD_WIDTH * LCD_HEIGHT / 10);
  static lv_disp_drv_t disp_drv;
  lv_disp_drv_init(&disp_drv);
  disp_drv.hor_res = LCD_WIDTH;
  disp_drv.ver_res = LCD_HEIGHT;
  disp_drv.flush_cb = my_disp_flush;
  disp_drv.draw_buf = &draw_buf;
  lv_disp_drv_register(&disp_drv);

  const esp_timer_create_args_t lvgl_tick_timer_args = {
    .callback = &example_increase_lvgl_tick,
    .name = "lvgl_tick"
  };
  esp_timer_handle_t lvgl_tick_timer = NULL;
  esp_timer_create(&lvgl_tick_timer_args, &lvgl_tick_timer);
  esp_timer_start_periodic(lvgl_tick_timer, EXAMPLE_LVGL_TICK_PERIOD_MS * 1000);

  // ==========================================
  // 修改点：完全照搬 DeviceCode 的 UI 绘制逻辑
  // ==========================================
  // 1. 设置黑色背景
  lv_obj_set_style_bg_color(lv_scr_act(), lv_color_hex(0x000000), LV_PART_MAIN);

  // 2. 电池 UI 标签 (完全沿用你的参考代码样式)
  label_battery = lv_label_create(lv_scr_act());
  lv_obj_set_width(label_battery, 200); 
  lv_obj_set_style_text_color(label_battery, lv_color_hex(0x00FF00), LV_PART_MAIN);
  lv_obj_set_style_text_font(label_battery, &lv_font_montserrat_24, LV_PART_MAIN);
  lv_label_set_text(label_battery, LV_SYMBOL_BATTERY_FULL " --%");
  lv_obj_set_style_text_align(label_battery, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);
  lv_obj_align(label_battery, LV_ALIGN_BOTTOM_MID, 0, -40);

  // 3. 原有 IMU 数据标签 (改为白色，防止在黑色背景上隐身)
  label = lv_label_create(lv_scr_act());
  lv_obj_set_width(label, disp_drv.hor_res);
  lv_obj_set_style_text_color(label, lv_color_hex(0xFFFFFF), LV_PART_MAIN);
  lv_obj_set_style_text_align(label, LV_TEXT_ALIGN_CENTER, 0);
  lv_obj_set_style_text_font(label, &lv_font_montserrat_40, 0);
  lv_obj_set_style_text_line_space(label, 10, 0);
  lv_obj_align(label, LV_ALIGN_CENTER, 0, -20); // 稍微往上移一点，不要挡住电量
  lv_label_set_text(label, "Initializing...");

  if (!qmi.begin(Wire, QMI8658_L_SLAVE_ADDRESS, IIC_SDA, IIC_SCL)) {
    lv_label_set_text(label, "Sensor Error!");
    while (1) { delay(1000); }
  }

  qmi.configAccelerometer(SensorQMI8658::ACC_RANGE_4G, SensorQMI8658::ACC_ODR_1000Hz, SensorQMI8658::LPF_MODE_0);
  qmi.enableAccelerometer();
}

void loop() {
  lv_timer_handler();

  // 定期刷新电池状态（这里保留了 2 秒读取一次的优化，防止 I2C 堵塞导致你主程序的 IMU 掉帧）
  static unsigned long lastBatteryUpdate = 0;
  if (millis() - lastBatteryUpdate > 2000) {
    lastBatteryUpdate = millis();
    char bat_buf[32];
    const char* pwr_icon = LV_SYMBOL_BATTERY_FULL;
    
    // 以下判断逻辑与 DeviceCode.ino 完全一致
    if (power.isVbusIn()) {
      pwr_icon = power.isCharging() ? LV_SYMBOL_CHARGE : LV_SYMBOL_USB;
    }

    if (power.isBatteryConnect()) {
      snprintf(bat_buf, sizeof(bat_buf), "%s %d%%", pwr_icon, power.getBatteryPercent());
    } else {
      snprintf(bat_buf, sizeof(bat_buf), "%s NO BAT", pwr_icon);
    }
    lv_label_set_text(label_battery, bat_buf);
  }

  // --- 读取 IMU 数据并通过蓝牙发送 ---
  if (qmi.getDataReady()) {
    if (qmi.getAccelerometer(acc.x, acc.y, acc.z)) {
      char buf[64];
      snprintf(buf, sizeof(buf), "X%+.2fY%+.2fZ%+.2f", acc.x, acc.y, acc.z);
      lv_label_set_text(label, buf);
      
      if (deviceConnected) {
          pTxCharacteristic->setValue(buf);
          pTxCharacteristic->notify();
      }
      Serial.println(buf);
    }
  }
  delay(50);
}