//  JappeOS-Messaging, A pipe messaging system for JappeOS/Linux.
//  Copyright (C) 2023  Jappe02
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU Affero General Public License as
//  published by the Free Software Foundation, either version 3 of the
//  License, or (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU Affero General Public License for more details.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.

import 'dart:io';
import 'package:event/event.dart';

/// Use this class to send/receive messages between processes
/// using the JappeOS messaging system.
class JappeOSMessaging {
  /// Check if the init() function was ever called.
  static bool get initDone => _initDone;
  static bool _initDone = false;

  static late ServerSocket _serverSocket;

  /// Get a list of connected clients.
  static List<Socket> get clients => _clients;
  static final List<Socket> _clients = [];

  /// Initialize the messaging system.
  static Future<void> init([int port = 8888]) async {
    if (_initDone) return;

    // Create a server socket
    _serverSocket = await ServerSocket.bind('localhost', port);
    print('Server listening on ${_serverSocket.address}:${_serverSocket.port}');

    _initDone = true;

    await for (var clientSocket in _serverSocket) {
      _handleClientConnection(clientSocket);
    }
  }

  /// Handles the connection of a client.
  static void _handleClientConnection(Socket clientSocket) {
    print('Client connected: ${clientSocket.remoteAddress}:${clientSocket.remotePort}');
    _clients.add(clientSocket);

    // Receive response from the server
    clientSocket.listen((data) {
      var request = String.fromCharCodes(data).trim();
      print('Received request from client: $request');

      //Message finalMsg = Message.fromString(request);
      //if (finalMsg.args.containsKey("__REC_CALLBACK__")) {
      //  send(Message("__CALLBCAK_MSG__", {"__RET__": "0"}), clientSocket);
      //}

      receive.broadcast(Message.fromString(request));
    });
  }

  /// Cleans up the messaging system.
  static void clean() async {
    for (Socket s in _clients) {
      s.flush();
      s.close();
    }
    await _serverSocket.close();
    _initDone = false;
  }

  /// Send a message to a target client.
  static void send(Message msg, [Socket? to]) {
    Message finalMsg = msg;
    finalMsg.args["__SENDER__"] = "${_serverSocket.address}+${_serverSocket.port}";

    if (to == null) {
      for (Socket s in _clients) {
        s.write(msg);
      }
    } else {
      to.write(msg);
    }
  }

  /// Send a message to a target client, but receive a result message.
  //static Future<Message?> sendAndCallback(Message msg, [Socket? to]) async {
  //  Message finalMsg = msg;
  //  int id = Random().nextInt(100);
  //  finalMsg.args["__REC_CALLBACK__"] = id.toString();
//
  //  if (to == null) {
  //    for (Socket s in _clients) {
  //      s.write(msg);
  //    }
  //  } else {
  //    to.write(msg);
  //  }
//
  //  Message? ret;
  //  receive.subscribe((msg) {
  //    if (to == null) {
  //      if (msg?.name != "__CALLBCAK_MSG__" || msg?.args["__REC_CALLBACK__"] != id.toString()) return;
//
  //      ret = msg;
  //    } else {
//
  //    }
  //  });
  //  return Future.value(ret);
  //}

  /// An event fired when a message is received.
  static final receive = Event<Message>();
}

/// A message that can be received and sent.
class Message extends EventArgs {
  /// The name of the [Message].
  String name;

  /// The args of the message, key is the name of the arg,
  /// value is the value of the arg, if other types are used,
  /// use the [toString] function of [Object].
  Map<String, String> args;

  /// Converts a [String] to a [Message].
  static Message fromString(String str) {
    Message result = Message(_getSubstringBeforeFirstSpace(str), {});

    var pairs = str.replaceFirst(result.name, "").trim().split(';');
    for (var pair in pairs) {
      var keyValue = pair.split(':');
      if (keyValue.length == 2) {
        var key = keyValue[0].replaceAll('"', '').trim();
        var value = keyValue[1].replaceAll(RegExp(r'(?<!\\)"'), '').replaceAll(r'\"', '"').trim();
        result.args[key] = value;
      }
    }

    return result;
  }

  /// Convert this [Message] to a [String].
  @override
  String toString() {
    String result = "${validateName(name)} ";

    args.forEach((key, value) {
      result += '"$key":"${value.replaceAll('"', r'\"')}";';
    });

    return result;
  }

  /// Make a name parameter of a [Message] ready to be sent.
  static String validateName(String str) {
    return str.replaceAll(" ", "-");
  }

  /// Get all text befor the first " " letter.
  static String _getSubstringBeforeFirstSpace(String input) {
    List<String> parts = input.split(' ');
    if (parts.isNotEmpty) {
      return parts.first;
    }
    return '';
  }

  /// Contruct a message.
  Message(this.name, this.args);
}
