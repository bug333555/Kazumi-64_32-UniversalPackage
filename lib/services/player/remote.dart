import 'dart:async';

import 'package:dlna_dart/dlna.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/player/dlna_transport_client.dart';
import 'package:kazumi/services/player/remote_cast_coordinator.dart';

class RemotePlay {
  Future<bool> castVideo(
    String video, {
    required Map<String, String> httpHeaders,
    String title = 'Kazumi',
  }) async {
    final searcher = DLNAManager();
    late final DeviceManager deviceManager;
    try {
      deviceManager = await searcher.start();
    } catch (error, stackTrace) {
      KazumiLogger().e(
        'RemotePlay: failed to start device discovery',
        error: error,
        stackTrace: stackTrace,
      );
      KazumiDialog.showToast(message: '无法启动 DLNA 设备搜索: $error');
      searcher.stop();
      return false;
    }
    final coordinator = RemoteCastCoordinator();
    StreamSubscription<Map<String, DLNADevice>>? subscription;
    var dialogActive = true;
    var devices = <DLNADevice>[];
    String? castingDeviceKey;
    var castAccepted = false;

    await KazumiDialog.show(
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            subscription ??= deviceManager.devices.stream.listen(
              (deviceMap) {
                if (!dialogActive) {
                  return;
                }
                final unique = <String, DLNADevice>{};
                for (final device in deviceMap.values) {
                  final info = device.info;
                  final controlUri = DlnaTransportClient.controlUriFor(info);
                  if (controlUri == null) {
                    KazumiLogger().d(
                      'RemotePlay: ignored non-renderer ${info.friendlyName} '
                      '${info.deviceType}',
                    );
                    continue;
                  }
                  unique['${info.URLBase}|$controlUri'] = device;
                }
                setState(() {
                  devices = unique.values.toList()
                    ..sort((left, right) => left.info.friendlyName
                        .compareTo(right.info.friendlyName));
                });
              },
              onError: (Object error, StackTrace stackTrace) {
                KazumiLogger().w(
                  'RemotePlay: device discovery failed',
                  error: error,
                  stackTrace: stackTrace,
                );
              },
            );

            return AlertDialog(
              title: const Text('远程投屏'),
              content: SizedBox(
                width: 420,
                child: devices.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 16),
                            Text('正在搜索支持 AVTransport 的设备'),
                          ],
                        ),
                      )
                    : SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: devices.map((device) {
                            final info = device.info;
                            final deviceKey =
                                '${info.URLBase}|${info.friendlyName}';
                            final isCasting = castingDeviceKey == deviceKey;

                            Future<void> startCast({
                              Iterable<RemoteCastStrategy>? strategies,
                            }) async {
                              setState(() {
                                castingDeviceKey = deviceKey;
                              });
                              try {
                                KazumiDialog.showToast(
                                  message: '尝试投屏至 ${info.friendlyName}',
                                );
                                final result = await coordinator.cast(
                                  info,
                                  video,
                                  httpHeaders: httpHeaders,
                                  title: title,
                                  strategies: strategies,
                                );
                                castAccepted = true;
                                KazumiLogger().i(
                                  'RemotePlay: ${result.strategy.name} '
                                  'accepted by ${info.friendlyName}, '
                                  'verified=${result.verifiedPlaying}',
                                );
                                final shouldDismiss = result.verifiedPlaying ||
                                    result.strategy ==
                                        RemoteCastStrategy.headerProxy;
                                KazumiDialog.showToast(
                                  message: result.verifiedPlaying
                                      ? '已在 ${info.friendlyName} 开始播放'
                                      : result.strategy ==
                                              RemoteCastStrategy.headerProxy
                                          ? '已向 ${info.friendlyName} 发送兼容播放命令'
                                          : '播放命令已发送；如电视未播放，请点右侧兼容投屏按钮',
                                );
                                if (shouldDismiss) {
                                  KazumiDialog.dismiss();
                                } else if (dialogActive) {
                                  setState(() {
                                    castingDeviceKey = null;
                                  });
                                }
                              } catch (error, stackTrace) {
                                KazumiLogger().e(
                                  'RemotePlay: failed to cast to device',
                                  error: error,
                                  stackTrace: stackTrace,
                                );
                                KazumiDialog.showToast(
                                  message:
                                      'DLNA 异常: $error\n请重新搜索或切换设备',
                                );
                                if (dialogActive) {
                                  setState(() {
                                    castingDeviceKey = null;
                                  });
                                }
                              }
                            }

                            return ListTile(
                              leading: const Icon(Icons.cast_connected),
                              title: Text(info.friendlyName),
                              subtitle: Text(_deviceTypeName(info.deviceType)),
                              trailing: isCasting
                                  ? const SizedBox.square(
                                      dimension: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : IconButton(
                                      tooltip: '兼容投屏',
                                      icon: const Icon(
                                        Icons.settings_input_antenna,
                                      ),
                                      onPressed: castingDeviceKey == null
                                          ? () => startCast(
                                                strategies: const [
                                                  RemoteCastStrategy.headerProxy,
                                                ],
                                              )
                                          : null,
                                    ),
                              enabled: castingDeviceKey == null,
                              onTap: castingDeviceKey == null
                                  ? () => startCast()
                                  : null,
                            );
                          }).toList(),
                        ),
                      ),
              ),
              actions: [
                TextButton(
                  onPressed: KazumiDialog.dismiss,
                  child: const Text('退出'),
                ),
                TextButton(
                  onPressed: () {
                    KazumiDialog.showToast(message: '正在搜索投屏设备');
                  },
                  child: const Text('搜索'),
                ),
              ],
            );
          },
        );
      },
      onDismiss: () {
        dialogActive = false;
        unawaited(subscription?.cancel());
        searcher.stop();
      },
    );
    if (dialogActive) {
      dialogActive = false;
      await subscription?.cancel();
      searcher.stop();
    }
    return castAccepted;
  }

  String _deviceTypeName(String deviceType) {
    final parts = deviceType.split(':');
    if (parts.length > 3 && parts[3].isNotEmpty) {
      return parts[3];
    }
    return 'MediaRenderer';
  }
}
