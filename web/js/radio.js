// Radio connection for the computer version: Bluetooth (Web Bluetooth, in Edge or Chrome) or a serial/COM port
// (Web Serial: a USB TNC, or a radio paired in Windows Bluetooth settings that shows up as a COM port).
// Like the iPhone app, it listens to everything the radio sends, logs the raw bytes, and decodes KISS or text packets.

import { RadioStreamDecoder } from "./aprs.js";

// Web Bluetooth can only open services named up front. TIDRADIO doesn't publish the H9's, so this lists the
// standard BLE KISS TNC service plus the serial-style services cheap radios commonly use. A service found
// with nRF Connect can be added on the Radio tab.
export const KNOWN_SERVICES = [
  "00000001-ba2a-46c9-ae49-01b0961f68bb",  // BLE KISS TNC (Mobilinkd, Benshi/BTECH, LoRa APRS)
  "6e400001-b5a3-f393-e0a9-e50e24dcca9e",  // Nordic UART
  "49535343-fe7d-4ae5-8fa9-9fafd205e455",  // Microchip transparent UART
  0xffe0, 0xfff0, 0xff00, 0xffe5, 0xffd0, 0xae00, 0xae30, 0xfee7, 0xff10, 0xfe59, 0x1801, 0x180a,
];
const KISS_RX = "00000003-ba2a-46c9-ae49-01b0961f68bb";

const hex = (b) => Array.from(b.slice(0, 48), (x) => x.toString(16).padStart(2, "0").toUpperCase()).join(" ") + (b.length > 48 ? " …" : "");
const printable = (b) => Array.from(b.slice(0, 64), (x) => (x >= 32 && x <= 126 ? String.fromCharCode(x) : ".")).join("");

export class RadioLink {
  constructor({ onPacket, onLog, onState }) {
    this.onPacket = onPacket; this.onLog = onLog; this.onState = onState;
    this.state = "Not connected";
    this.decoders = new Map();
    this.flushTimers = new Map();
    this.channels = [];
    this.packets = 0;
    this.userDisconnected = false;
  }

  static get bluetoothAvailable() { return !!(navigator.bluetooth && navigator.bluetooth.requestDevice); }
  static get serialAvailable() { return !!navigator.serial; }

  setState(s) { this.state = s; this.onState?.(s); }
  note(text) { this.onLog?.(text); }

  async connectBluetooth(extraServices = [], showAll = false) {
    const services = [...KNOWN_SERVICES, ...extraServices.map((s) => s.toLowerCase())];
    const options = showAll
      ? { acceptAllDevices: true, optionalServices: services }
      : { filters: ["TD-", "H9", "TID", "RADIO", "TNC", "KISS"].map((p) => ({ namePrefix: p })).concat([{ services: [services[0]] }]), optionalServices: services };
    const device = await navigator.bluetooth.requestDevice(options);
    this.device = device;
    this.userDisconnected = false;
    device.addEventListener("gattserverdisconnected", () => this.onBluetoothDrop());
    await this.openGatt();
  }

  async openGatt() {
    const device = this.device;
    this.setState(`Connecting to ${device.name || "radio"}…`);
    const server = await device.gatt.connect();
    this.channels = [];
    this.decoders.clear();
    this.note(`Connected to ${device.name || "radio"}. Looking at what it offers…`);
    const services = await server.getPrimaryServices();
    if (!services.length) this.note("The radio didn't offer any service this app knows. Add its service ID below (from nRF Connect) and connect again.");
    let pinned = null;
    for (const svc of services) {
      this.note(`Service ${svc.uuid}${svc.uuid === KNOWN_SERVICES[0] ? " (KISS TNC!)" : ""}`);
      let chars = [];
      try { chars = await svc.getCharacteristics(); } catch (e) { continue; }
      for (const c of chars) {
        const p = c.properties;
        const props = ["read", "write", "writeWithoutResponse", "notify", "indicate"].filter((k) => p[k]).join(", ");
        this.note(`  Characteristic ${c.uuid} [${props}]`);
        const ch = { id: c.uuid, service: svc.uuid, props, bytes: 0, subscribed: false };
        this.channels.push(ch);
        if (p.notify || p.indicate) {
          try {
            c.addEventListener("characteristicvaluechanged", (ev) => this.handle(new Uint8Array(ev.target.value.buffer), ch));
            await c.startNotifications();
            ch.subscribed = true;
          } catch (e) {
            this.note(`  Couldn't subscribe to ${c.uuid}: ${e.message}`);
          }
        }
        if (c.uuid === KISS_RX) pinned = c.uuid;
      }
    }
    if (pinned) { this.listenOnlyTo = pinned; this.note("  Found the standard KISS data channel; listening to it only."); }
    this.setState(`Connected to ${device.name || "radio"}`);
  }

  onBluetoothDrop() {
    this.setState("Not connected");
    this.note("Disconnected");
    // Riding out of range or the radio rebooting shouldn't need a click to recover.
    if (!this.userDisconnected && this.device) {
      setTimeout(() => this.openGatt().catch((e) => { this.note(`Reconnect failed: ${e.message}`); this.onBluetoothDrop(); }), 3000);
    }
  }

  async connectSerial(baudRate = 9600) {
    const port = await navigator.serial.requestPort();
    await port.open({ baudRate });
    this.port = port;
    this.userDisconnected = false;
    const ch = { id: "serial", service: "COM port", props: `${baudRate} baud`, bytes: 0, subscribed: true };
    this.channels = [ch];
    this.decoders.clear();
    this.setState("Connected to serial port");
    this.note(`Opened serial port at ${baudRate} baud. Waiting for packets…`);
    (async () => {
      while (port.readable && !this.userDisconnected) {
        const reader = port.readable.getReader();
        this.reader = reader;
        try {
          for (;;) {
            const { value, done } = await reader.read();
            if (done) break;
            if (value?.length) this.handle(value, ch);
          }
        } catch (e) {
          this.note(`Serial read error: ${e.message}`);
        } finally {
          reader.releaseLock();
        }
      }
      this.setState("Not connected");
    })();
  }

  async disconnect() {
    this.userDisconnected = true;
    try { this.device?.gatt?.disconnect(); } catch (e) { /* already gone */ }
    try { await this.reader?.cancel(); await this.port?.close(); } catch (e) { /* already closed */ }
    this.device = null; this.port = null;
    this.setState("Not connected");
  }

  handle(bytes, ch) {
    ch.bytes += bytes.length;
    this.note(`RX ${ch.id.slice(0, 8)} ${bytes.length}B: ${hex(bytes)}  |${printable(bytes)}|`);
    if (this.listenOnlyTo && this.listenOnlyTo !== ch.id) return;
    let d = this.decoders.get(ch.id);
    if (!d) this.decoders.set(ch.id, (d = new RadioStreamDecoder()));
    this.deliver(d.feed(Array.from(bytes)));
    this.mode = d.mode;
    // Some radios send one packet per notification with no line ending; decode it once things go quiet.
    clearTimeout(this.flushTimers.get(ch.id));
    this.flushTimers.set(ch.id, setTimeout(() => this.deliver(d.flush()), 400));
  }

  deliver(packets) {
    for (const p of packets) {
      this.packets++;
      this.onPacket?.(p);
    }
  }
}
