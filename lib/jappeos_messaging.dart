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
import 'dart:typed_data';
import 'package:event/event.dart';

/// Use this class to send/receive messages between processes
/// using the JappeOS messaging system.
class MessagingPipe {
  /// Holds a static list of all [MessagingPipe] instances created in this app.
  static final Map<String, int> _instances = <String, int>{};

  /// Return the static list of all [MessagingPipe] instances created in this app.
  static Map<String, int> get instances => _instances;

  /// Contruct a messaging pipe object.
  /// Calls the init method, see: [_init].
  /// NOTE: Remember to call [clean] after using this [MessagingPipe] to clean up all resources.
  MessagingPipe(int port, {void Function(dynamic)? onError, void Function()? onDone}) {
    _init(port, onError, onDone);
  }

  /// Holds a list of clients connected to this instance.
  final List<Socket> _clients = [];

  /// The name of this pipe.
  late String _name;

  /// Get the name of this pipe.
  String get name => _name;

  /// Initializes the messaging system with a `port` to use.
  /// This makes it possible for the "server" (this process)
  /// to send and receive [Message]s using the other methods
  /// provided by this class.
  Future<void> _init(int port, void Function(dynamic)? onError, void Function()? onDone) async {
    _name = "MessageHandler-$port";

    ServerSocket.bind('localhost', port).then((serverSocket) {
      // Handle successful server startup. >>
      print('Server listening on ${serverSocket.address}:${serverSocket.port}');

      // Add this instance.
      _instances[name] = port;

      if (onDone != null) onDone();

      // Handle connection of a client.
      serverSocket.listen((clientSocket) {
        if (!_clients.contains(clientSocket)) {
          _clients.add(clientSocket);
          print('New client connected: ${clientSocket.address}:${clientSocket.port}');

          // Start listening for messages from the client & invoke the 'receive' event.
          clientSocket.listen((data) {
            _handleClientData(clientSocket, data);
          }, onDone: () {
            // When the client disconnects.
            _handleClientDisconnection(clientSocket);
          });
        }
      });
    }).catchError((error) {
      // Handle failed server startup. >>
      if (onError != null) onError(error);
      clean();
      print('Failed to start server: $error');
    });
  }

  /// Handle data received from a connected client.
  void _handleClientData(Socket clientSocket, Uint8List data) async {
    var request = String.fromCharCodes(data).trim();
    print('Received request from client (${clientSocket.address}:${clientSocket.port}): $request');
    receive.broadcast(Values(Message.fromString(request), clientSocket));
  }

  /// Handle the disconnection of a client, a client needs
  /// to connect first to send messages.
  void _handleClientDisconnection(Socket clientSocket) async {
    print('Client disconnected: ${clientSocket.address}:${clientSocket.port}');
    _clients.remove(clientSocket);
  }

  /// Stops the "server" (this process) and cleans everything up.
  /// After this method is called, [Message]s can no longer
  /// be sent or received from/to this instance.
  void clean() async {
    // Remove this instance.
    _instances.remove(_name);

    for (Socket clientSocket in _clients) {
      clientSocket.flush();
      clientSocket.close();
    }
    _clients.clear();
  }

  /// Sends a [Message] object to another process listening on
  /// `port`. A message can contain a lot of data, see: [Message].
  Future<MessageOperationResult> send(int port, Message msg) async {
    Socket.connect('localhost', port, timeout: Duration(seconds: 5)).then((socket) {
      // Connect, Write, Disconnect.
      socket.write(msg.toString());
      //socket.flush();
      //socket.close();
      print('Message sent to localhost:$port');
      return Future.value(MessageOperationResult.success());
    }).catchError((error) {
      print('Error occurred while sending message: $error');
      return Future.value(MessageOperationResult.error(error.toString()));
    });
    // TODO: Fix random unknown error message and "Bad state: StreamSink is bound to a stream".
    // If nothing is returned here yet, it is obviously an error.
    //print('Failed to send message: Unknown Error');
    return Future.value(MessageOperationResult.success());
  }

  /// An [Event] that can be listened to. Listen for [Message]s
  /// sent to this instance, a message can contain a lot of data,
  /// see: [Message]. For the use of the event system, see: [Event].
  final receive = Event<Values<Message, Socket>>();
}

/// A message that can be first sent, then received somewhere else.
/// See [MessagingPipe.send] and [MessagingPipe.receive] for
/// using the messaging system to send/receive messages between
/// separate processes.
class Message extends EventArgs {
  /// The name/ID of the message to be sent, should not contain spaces.
  /// This name should also be unique, to be sure, numbers can be used
  /// as a prefix/suffix if needed.
  String name;

  /// The arguments of the message, can be left empty. Key & Value.
  /// These args are used to transport data alongside the message.
  Map<String, String> args;

  /// Converts any [String] to a new [Message] object.
  static Message fromString(String str) {
    Message result = Message(_getSubstringBeforeFirstSpace(str), {});

    var pairs = str.replaceFirst(result.name, "").trim().split(RegExp(r'(?<!\\);'));
    for (var pair in pairs) {
      var keyValue = pair.split(RegExp(r'(?<!\\):'));
      if (keyValue.length == 2) {
        var key = _doIllegalCharacters(keyValue[0].replaceAll(RegExp(r'(?<!\\)"'), ''), false).trim();
        var value = _doIllegalCharacters(keyValue[1].replaceAll(RegExp(r'(?<!\\)"'), ''), false).trim();
        result.args[key] = value;
      }
    }

    result.name = validateName(result.name, false);
    return result;
  }

  /// Converts this [Message] object to a [String] type.
  @override
  String toString() {
    String result = "${validateName(name, true)} ";

    args.forEach((key, value) {
      result += '"${_doIllegalCharacters(key, true)}":"${_doIllegalCharacters(value, true)}";';
    });

    return result;
  }

  /// Fixes invalid message names.
  ///
  /// If `toEscaped` is true, a `\` will be added before the illegal character,
  /// if false, it does the opposite.
  static String validateName(String str, bool toEscaped) {
    return toEscaped ? str.replaceAll(" ", r"\-") : str.replaceAll(r"\-", " ");
  }

  /// Get all text before the first " " letter in a [String].
  static String _getSubstringBeforeFirstSpace(String input) {
    List<String> parts = input.split(' ');
    if (parts.isNotEmpty) {
      return parts.first;
    }
    return '';
  }

  /// Add / Remove escape characters from a string with illegal characters.
  /// This has to be done because the message is sent as a string, and uses
  /// characters like ":" and ";" to separate parts of the message.
  ///
  /// If `toEscaped` is true, a `\` will be added before the illegal character,
  /// if false, it does the opposite.
  static String _doIllegalCharacters(String str, bool toEscaped) {
    String retStr = str;
    List<String> chars = ['"', ';', ':'];

    if (toEscaped) {
      for (var c in chars) {
        retStr = retStr.replaceAll(c, r"\" + c);
      }
    } else {
      for (var c in chars) {
        retStr = retStr.replaceAll(r"\" + c, c);
      }
    }

    return retStr;
  }

  /// Contruct a [Message] object containing a required name,
  /// the name should not have any blank spaces. `args` can
  /// be empty, not null.
  Message(this.name, this.args);
}

/// The result of a messaging operation like send().
class MessageOperationResult {
  /// Whether the operation was successful or not. Cannot be null.
  final bool success;

  /// Other info. Can be displayed as a message to a user to give more
  /// information about the error. A successful operation does not need this.
  /// Can be null if no info was provided.
  final String? info;

  /// Construct a successful operation, no additional info can be added.
  factory MessageOperationResult.success() {
    return MessageOperationResult._(true, null);
  }

  /// Contruct a operation result that resulted in an error. Additional info
  /// can be provided, if any.
  factory MessageOperationResult.error(String? info) {
    return MessageOperationResult._(false, null);
  }

  /// Private contructor to construct a [MessageOperationResult].
  MessageOperationResult._(this.success, this.info);
}
