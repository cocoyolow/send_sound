//
//  Generated file. Do not edit.
//

import FlutterMacOS
import Foundation

import audio_session
import ble_peripheral
import just_audio

func RegisterGeneratedPlugins(registry: FlutterPluginRegistry) {
  AudioSessionPlugin.register(with: registry.registrar(forPlugin: "AudioSessionPlugin"))
  BlePeripheralPlugin.register(with: registry.registrar(forPlugin: "BlePeripheralPlugin"))
  JustAudioPlugin.register(with: registry.registrar(forPlugin: "JustAudioPlugin"))
}
