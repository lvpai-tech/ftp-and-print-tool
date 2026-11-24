import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void setMockWorkstationCredentials(Map<String, String> values) {
  FlutterSecureStorage.setMockInitialValues(values);
  if (!Platform.isMacOS) return;
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('ai.lvpai.ftp/login-keychain'),
        (call) async {
          switch (call.method) {
            case 'read':
              return storage.read(key: call.arguments['key'] as String);
            case 'write':
              await storage.write(
                key: call.arguments['key'] as String,
                value: call.arguments['value'] as String,
              );
              return null;
            case 'delete':
              await storage.delete(key: call.arguments['key'] as String);
              return null;
            case 'containsKey':
              return storage.containsKey(key: call.arguments['key'] as String);
            case 'readAll':
              final entries = await storage.readAll();
              final args = call.arguments as Map?;
              final prefixes = (args?['prefixes'] as List?)?.cast<String>();
              if (prefixes == null) return entries;
              final keys = args!['keys'] as List;
              return {
                for (final entry in entries.entries)
                  if (keys.contains(entry.key) ||
                      prefixes.any(entry.key.startsWith))
                    entry.key: entry.value,
              };
          }
          throw MissingPluginException(call.method);
        },
      );
}
