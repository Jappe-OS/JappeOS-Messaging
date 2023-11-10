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

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'package:event/event.dart';
import 'package:uuid/uuid.dart';

//
// TODO: Test the whole messaging system and all of its features!!! Todo set: November 9, 2023.
//

/// Use to represent **unknown** values in [String] objects that are either logged
/// to the console, or used in an exception.
const _kUnknownPlaceholder = "<unknown>";

/// Use to represent **invalid** values in [String] objects that are either logged
/// to the console, or used in an exception.
const _kInvalidPlaceholder = "<invalid>";

/// Use this class to send/receive messages between processes using the JappeOS
/// messaging system.
class MessagingPipe {
  /// Holds a static list of all [MessagingPipe] instances created in this app.
  static final List<String> _instances = [];

  /// Return the static list of all [MessagingPipe] instances created in this app.
  static List<String> get instances => _instances;

  /// A private constructor to construct with name.
  MessagingPipe._(String name) {
    _name = name;
  }

  /// The server of this messaging pipe.
  late ServerSocket _serverSocket;

  /// The servers [StreamSubscription] that listens to data from clients.
  late StreamSubscription<Socket> _serverListenerSubscription;

  /// Holds a list of clients connected to this instance.
  ///
  /// [Socket] is the socket that has connected to this instance.
  ///
  /// [MessagingAddress] is the address of the socket which connected to this instance.
  final Map<Socket, MessagingAddress> _clientsConnected = {};

  /// Holds a list of clients this instance has connected to.
  ///
  /// [Socket] is the socket this intance is connected to.
  ///
  /// [MessagingAddress] is the address this instance is connected to.
  final Map<Socket, MessagingAddress> _connectedTo = {};

  /// The name of this pipe.
  late String _name;

  /// Get the name of this pipe.
  String get name => _name;

  /// Get the address of this pipe.
  String get address => _serverSocket.address.address;

  /// Get a list of addresses of remote instances connected to this instance.
  List<String?> get connectedFromAddresses => _clientsConnected.values.toList().map((address) => address.getAddress()).toList();

  /// Get a list of addresses that this instance is connected to.
  List<String?> get connectedToAddresses => _connectedTo.values.toList().map((address) => address.getAddress()).toList();

  /// Initializes the messaging system with a `name` to use.
  /// This makes it possible for the "server" (this process) to send and receive
  /// [Message]s using the other methods provided by this class.
  ///
  /// [MessagingPipe] will return null if an error has occurred.
  ///
  /// NOTE: Remember to call [clean] after using this [MessagingPipe] to clean up all resources.
  static Future<MessagingPipe?> init(String name, [bool useCustomDirectory = false]) async {
    name = MessagingAddress(name).getAddress(true) ?? "";
    if (!Platform.isLinux) {
      throw Exception("Unsupported platform! 'Platform.isLinux' returned false.");
    } else if (_instances.contains(name)) {
      throw Exception("A messaging pipe with the name '$name' is already initialised!");
    }

    MessagingPipe thisObj = MessagingPipe._(name);
    InternetAddress address;
    var runtimeDir = MessagingAddress(Platform.environment['XDG_RUNTIME_DIR']).getAddress(true);

    // Set address
    if (useCustomDirectory) {
      address = InternetAddress(name, type: InternetAddressType.unix);
    } else {
      if (runtimeDir == null) throw Exception("The environment variable 'XDG_RUNTIME_DIR' returned null.");
      address = InternetAddress('$runtimeDir/$name', type: InternetAddressType.unix);
    }

    // Bind server socket
    try {
      thisObj._serverSocket = await ServerSocket.bind(address, 0);
    } catch (e) {
      // Handle failed server startup. >>
      thisObj.clean();
      print('Failed to start server: $e');
      return Future.value(null);
    }

    // Handle successful server startup. >>
    print('Server listening on: ${address.address}');

    // Add this instance.
    _instances.add(address.address);

    // Handle connection of a client that is connected to this instance.
    thisObj._serverListenerSubscription = thisObj._serverSocket.listen((clientSocket) async {
      // Client connection is handled here.
      MessagingAddress? clientAddress;
      StreamSubscription<Uint8List>? clientSubscription;

      // Wait for hello message
      try {
        clientAddress = await thisObj._handleClientHelloMessage(clientSocket);
      } catch (e) {
        clientSocket.close().then((p0) => thisObj._handleClientDisconnection(clientSocket));
        print('Failed to receive hello message from remote instance (${clientAddress!.getAddress(true) ?? _kInvalidPlaceholder}): $e');
        return;
      }

      // Succesful connection >>
      print('New remote client connected: ${clientAddress.getAddress()}');
      thisObj._clientsConnected[clientSocket] = clientAddress;

      // Start listening for messages from the client & invoke the 'receive' event.
      clientSubscription = clientSocket.listen((data) async {
        // When the client sends data.
        thisObj._handleClientData(clientSocket, data);
      }, onDone: () async {
        // When the client disconnects.
        clientSubscription?.cancel();
        thisObj._handleClientDisconnection(clientSocket);
      });
    });

    return Future.value(thisObj);
  }

  /// Handle the hello message sent from a client that just connected to this instance.
  Future<MessagingAddress> _handleClientHelloMessage(Socket clientSocket) async {
    final completer = Completer<MessagingAddress>();
    StreamSubscription<Uint8List> clientListener;

    clientListener = clientSocket.listen(
      (data) async {
        var request = String.fromCharCodes(data).trim();
        var received = Message.fromString(request);

        if (received._name == _SpecialMessages.kMSG_NAME_HelloMsg && received.args.containsKey(_SpecialMessageArgs.kMSG_ARG_MsgAddress)) {
          var address = MessagingAddress(received.args[_SpecialMessageArgs.kMSG_ARG_MsgAddress]);
          if (address.getAddress() == null) return;

          completer.complete(address);
        }
      },
    );

    Timer? timeoutTimer;
    timeoutTimer = Timer(Duration(seconds: 5), () {
      if (!completer.isCompleted) {
        // Timeout occurred
        completer.complete(MessagingAddress(null));
      }
      timeoutTimer!.cancel();
    });

    var finalResult = await completer.future; // Wait for either completion or timeout

    // Make sure to cancel the listener after the future completes
    clientListener.cancel();

    // Throw exception incase of a timeout
    if (finalResult.getAddress() == null) throw Exception("Handling hello message timed out!");

    return finalResult;
  }

  /// Handle data received from a client connected to this instance.
  void _handleClientData(Socket clientSocket, Uint8List data) async {
    var request = String.fromCharCodes(data).trim();
    print('Received request from remote instance (${_clientsConnected[clientSocket]!.getAddress(true) ?? _kUnknownPlaceholder}): $request');
    receiveAll.broadcast(MessageEventArgs(clientSocket, Message.fromString(request)));
  }

  /// Handle the disconnection of a client coonected to this instance,
  /// a client needs to connect first to send messages.
  void _handleClientDisconnection(Socket clientSocket) async {
    print('Client disconnected: ${_clientsConnected[clientSocket]?.getAddress(true) ?? _kUnknownPlaceholder}');
    _clientsConnected.remove(clientSocket);
  }

  /// Stops this "server" (this instance) and cleans everything up.
  /// After this method is called, [Message]s can no longer be sent or received
  /// from/to this instance.
  void clean() async {
    receiveAll.unsubscribeAll();

    // Close all socket connections connected to this instance.
    _clientsConnected.forEach((key, value) async {
      key.close();
    });
    _clientsConnected.clear();

    // Close all socket connections this instance has connected to.
    _connectedTo.forEach((key, value) {
      key.close();
    });
    _connectedTo.clear();

    // Remove this instance.
    print('Server closed on: ${_serverSocket.address.address}');
    _instances.remove(_name);
    _serverListenerSubscription.cancel();
    _serverSocket.close();
  }

  /// Sends a [Message] object to a remote instance listening on `address`.
  /// A message can contain a lot of data, see: [Message].
  ///
  /// Keeping `onCallback` as null will make this message not receive a callback.
  void send(String address, Message msg, {void Function(Future<Message>)? onCallback}) async {
    address = MessagingAddress(address).getAddress(true) ?? "";
    Socket? socket = await _connectTo(address);

    if (socket == null) {
      var errMsg = "Failed to send message to remote instance due to connection error! Target address: $address";
      print(errMsg);
      throw Exception(errMsg);
    }

    msg._fromToAddr = MessagingAddress(_serverSocket.address.address);
    final operationResult = MessageSendOperation(
      pipeRef: this,
      sendToAddress: MessagingAddress(address),
      sendToUUID: onCallback != null ? Uuid.parse(Uuid().v4()) : null,
    );

    if (onCallback != null) onCallback(operationResult.waitForCallback());
    socket.write(msg.toString());
    print('Message sent from this instance to [remote instance] (TARGET address!): $address${onCallback != null ? ". Expecting callback." : ""}');
  }

  /// Connect this instance to a remote instance using an `address`.
  ///
  /// The returned [Socket] is the socket that this instance connected to.
  /// The connection has failed if the [Socket] is `null`.
  Future<Socket?> _connectTo(String address) async {
    address = MessagingAddress(address).getAddress(true) ?? "";

    // Check for multiple connections from this instance to the same initial address.
    if (_connectedTo.values.any((s) => s.getAddress() == address)) {
      //print(
      //    'Error occurred while connecting this instance to a remote instance (TARGET address!): $address. Initial address is already in use! Returning original Socket instead.');
      return Future.value(_connectedTo.keys.firstWhere((k) => _connectedTo[k] == _connectedTo.values.firstWhere((s) => s.getAddress() == address)));
    }

    // A function to send a hello message to the remote instance
    Future<void> sayHello(Socket socket) async {
      final message = _SpecialMessages.constructHelloMessage(MessagingAddress(_serverSocket.address.address));

      socket.write(message.toString());
    }

    try {
      Socket socket = await Socket.connect(InternetAddress(address, type: InternetAddressType.unix), 0, timeout: Duration(seconds: 5));
      print('This instance connected to [remote instance] (TARGET address!): $address');
      _connectedTo[socket] = MessagingAddress(address);

      await sayHello(socket);
      socket.listen((_) {}, onDone: () async => _disconnectFrom(socket));

      return Future.value(socket);
    } catch (error) {
      print('Error occurred while connecting this instance to a remote instance: $error');
      return Future.value(null);
    }
  }

  /// Disconnect this instance from a remote instance.
  void _disconnectFrom(Socket socket) async {
    if (!_connectedTo.containsKey(socket)) return;

    print('This instance disconnected from [remote instance]: ${socket.remoteAddress.address}');
    _connectedTo.remove(socket);
    socket.close();
  }

  /// An [Event] that can be listened to. Listen for [Message]s sent from a
  /// remote instance to this instance, a message can contain a lot of data,
  /// see: [Message].
  /// For the use of the event system, see: [Event].
  final receiveAll = Event<MessageEventArgs>();

  /// Uses [Event].
  /// Listen for [Message]s sent from a remote instance to this instance
  /// using a specific port, a message can contain a lot of data, see: [Message].
  void receive(String address, void Function(MessageEventArgs?) handler, [bool allowCallbackReplyMessages = false]) {
    receiveAll.subscribe((p0) {
      if (p0!.data._fromToAddr.getAddress() == address) {
        if (!allowCallbackReplyMessages && p0.data.type == MessageType.callbackReply) return;

        handler(p0);
      }
    });
  }
}

/// A class that contains special messages with special IDs that need to be
/// sent in order for the messaging system to work.
class _SpecialMessages {
  /// The name of a hello message.
  /// ignore: constant_identifier_names
  static const kMSG_NAME_HelloMsg = "__HELLO__";

  /// Construct a hello message ([kMSG_NAME_HelloMsg]).
  /// The `address` is used to send the address with the message.
  static Message constructHelloMessage(MessagingAddress address) {
    return Message.normal(kMSG_NAME_HelloMsg, {_SpecialMessageArgs.kMSG_ARG_MsgAddress: address.getAddress() ?? ""});
  }

  /// The name of a callback (answer) message.
  /// ignore: constant_identifier_names
  static const kMSG_NAME_CallbackMsg = "__CALLBACK__";
}

/// A class that contains special arguments (key-value pairs) to be sent
/// within messages
class _SpecialMessageArgs {
  /// The ARGUMENT (key) name of an address in a message.
  /// The value of this address should contain the address the message came from.
  // ignore: constant_identifier_names
  static const kMSG_ARG_MsgAddress = "__MSGDAT_ADDRESS__";

  // ignore: constant_identifier_names
  static const kMSG_ARG_MsgCallbackUUID = "__MSGDAT_CALLBACK_UUID__";

  // ignore: constant_identifier_names
  static const kMSG_ARG_MsgCallbackType = "__MSGDAT_CALLBACK_TYPE__";
}

/// `normal`: A normal message that can receive a callback.
///
/// `callbackReply`: A (callback) "reply" to a normal message
enum MessageType { normal, callbackReply }

/// The type of a message (callback) reply. an be used to know if an error was
/// returned for example.
class MessageCallbackReplyType {
  static const _unspecified = "unspecified", _success = "success", _error = "error";

  final String _val;
  String get value => _val;

  const MessageCallbackReplyType._(this._val);

  factory MessageCallbackReplyType.unspecified() {
    return MessageCallbackReplyType._(_unspecified);
  }

  factory MessageCallbackReplyType.success() {
    return MessageCallbackReplyType._(_success);
  }

  factory MessageCallbackReplyType.error() {
    return MessageCallbackReplyType._(_error);
  }

  @override
  String toString() => value;

  static MessageCallbackReplyType fromString(String? str) {
    switch (str) {
      case _unspecified:
        return MessageCallbackReplyType.unspecified();
      case _success:
        return MessageCallbackReplyType.success();
      case _error:
        return MessageCallbackReplyType.error();
      default:
        return MessageCallbackReplyType.unspecified();
    }
  }
}

/// A message that can be first sent, then received somewhere else.
/// See [MessagingPipe.send] and [MessagingPipe.receive] for using the
/// messaging system to send/receive messages between separate processes.
class Message {
  /// If the type of the sent message is `normal`, the message is a normal
  /// message that can (but does not have to) require a (callback) reply.
  ///
  /// If the type of the sent message is `callbackReply`, the message is a
  /// reply to another message.
  MessageType get type => _callbackIsReply ? MessageType.callbackReply : MessageType.normal;

  /// The name/ID of the message to be sent, should not contain spaces.
  /// This name should also be unique, to be sure, numbers can be used as a
  /// prefix/suffix if needed.
  String get name => _name;
  String _name;

  /// The arguments of the message, can be left empty. Key & Value.
  /// These args are used to transport data alongside the message.
  UnmodifiableMapView<String, String> get args => UnmodifiableMapView(_args);
  Map<String, String> _args;

  /// The address this message was sent from, or will be sent to.
  MessagingAddress get remoteAddress => _fromToAddr;
  MessagingAddress _fromToAddr = MessagingAddress(null);

  /// UUID to first send, and then receive a [Message] to reply to. A message
  /// needs to have this UUID in order to receive a reply, the reply message will
  /// have this same UUID, but the type is [Message.callbackReply].
  /// See: [Uuid], and [Message.callbackReply].
  UnmodifiableListView<int>? get callbackUUID => _callbackUUID != null ? UnmodifiableListView(_callbackUUID!) : null;
  List<int>? _callbackUUID;

  /// The type of the callback **reply**. Can be used to know if an error was
  /// returned. [MessageType] of this message needs to be [MessageType.callbackReply]
  /// in order for this value not to be null.
  MessageCallbackReplyType? get callbackReplyType => type == MessageType.callbackReply ? _callbackReplyType : null;
  MessageCallbackReplyType? _callbackReplyType;

  /// Wether the callback is a reply or not.
  /// Returns `false` if this message does not have a callback or the callback is
  /// not a reply (The callback may be a normal message that can be replied to.).
  bool _callbackIsReply = false;

  /// Converts any [String] to a new [Message] object.
  static Message fromString(String str) {
    Message result = Message._(_getSubstringBeforeFirstSpace(str), {});

    var pairs = str.replaceFirst(result._name, "").trim().split(RegExp(r'(?<!\\);'));
    for (var pair in pairs) {
      var keyValue = pair.split(RegExp(r'(?<!\\):'));
      if (keyValue.length == 2) {
        var key = _doIllegalCharacters(keyValue[0].replaceAll(RegExp(r'(?<!\\)"'), ''), false).trim();
        var value = _doIllegalCharacters(keyValue[1].replaceAll(RegExp(r'(?<!\\)"'), ''), false).trim();
        result._args[key] = value;
      }
    }

    {
      // Special keyvalue pair: address
      if (MessagingAddress(result._args[_SpecialMessageArgs.kMSG_ARG_MsgAddress]).getAddress() != null) {
        result._fromToAddr = MessagingAddress(result._args[_SpecialMessageArgs.kMSG_ARG_MsgAddress]);
      }

      // Special keyvalue pair: callback ID TODO: test
      if (result._args[_SpecialMessageArgs.kMSG_ARG_MsgCallbackUUID] != null) {
        result._callbackUUID = Uuid.parse(result._args[_SpecialMessageArgs.kMSG_ARG_MsgCallbackUUID]!);

        // If this message is a reply to an other message
        if (result._name == _SpecialMessages.kMSG_NAME_CallbackMsg) {
          result._callbackIsReply = true;

          result._callbackReplyType = MessageCallbackReplyType.fromString(result._args[_SpecialMessageArgs.kMSG_ARG_MsgCallbackType]);
        }
      }
    }

    result._name = validateName(result._name, false);
    return result;
  }

  /// Converts this [Message] object to a [String] type.
  @override
  String toString() {
    String result = "${validateName(_name, true)} ";

    {
      // Special keyvalue pair: address
      if (_fromToAddr.getAddress() != null) {
        _args[_SpecialMessageArgs.kMSG_ARG_MsgAddress] = _fromToAddr.getAddress()!;
      }

      // Special keyvalue pair: callback ID TODO: test
      if (_callbackUUID != null) {
        _name = _SpecialMessages.kMSG_NAME_CallbackMsg;
        _args[_SpecialMessageArgs.kMSG_ARG_MsgCallbackUUID] = Uuid.unparse(_callbackUUID!);

        // If this message is a reply to an other message
        if (_callbackIsReply) {
          _args[_SpecialMessageArgs.kMSG_ARG_MsgCallbackType] = _callbackReplyType.toString();
        }
      }
    }

    _args.forEach((key, value) {
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

  /// Get all text before the first " " (whitespace) letter in a [String].
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

  /// Construct a [Message] object privately with all possible settings.
  Message._(String? name, this._args, {List<int>? callbackUUID, bool isReply = false, MessageCallbackReplyType? callbackReplyType})
      : assert(isReply || name != null, "Message names can only be null when the message is a (callback) reply to an other message."),
        _name = isReply ? _SpecialMessages.kMSG_NAME_CallbackMsg : name ?? "",
        _callbackUUID = callbackUUID,
        _callbackIsReply = isReply,
        _callbackReplyType = isReply ? (callbackReplyType ?? MessageCallbackReplyType.unspecified()) : null;

  /// Constructs a normal message that can require a callback back from the
  /// address it was first sent to.
  Message.normal(String name, Map<String, String> args, {List<int>? callbackUUID}) : this._(name, args, callbackUUID: callbackUUID);

  /// Constructs a callback reply message that can reply to a normal message
  /// sent from another address. See: [Message.normal], and [MessagingPipe.send].
  Message.callbackReply(List<int>? callbackUUID, Map<String, String> args, {MessageCallbackReplyType? callbackReplyType})
      : this._(null, args, callbackUUID: callbackUUID, isReply: true, callbackReplyType: callbackReplyType);
}

/// The address that gets sent within a [Message]. The address is the path to
/// the source Unix Domain Socket file.
class MessagingAddress implements Comparable<String> {
  /// Error message to throw when trying to invoke `toString()`.
  static const String _kErrMsg = "Invoking 'toString()' on an instance of MessageAddress is not supported! Use 'getAddress()' instead.";

  /// The address of this object. Cannot be modified externally after this
  /// object has been instantiated. The address should be the path to the
  /// Unix Domain Socket file.
  final String? _address;

  /// Returns null if the address is invalid.
  ///
  /// RULE: Note! Always only compare with a [String] that has invoked the
  /// `toMessageAddressString()` mathod from the [_MessageAddressExt] extension.
  ///
  /// If `useInvalidAddressStringPlaceholder` is true, this method will never
  /// return null, instead, it will return "<invalid>". If this function returns
  /// "<invalid>", it is always an invalid address (in that case).
  String? getAddress([bool useInvalidAddressStringPlaceholder = false]) {
    if (_address == null || _address == "" || _address == _kInvalidPlaceholder) {
      if (useInvalidAddressStringPlaceholder) {
        return _kInvalidPlaceholder;
      } else {
        return null;
      }
    }

    return _address!.trim().replaceAll(r"\", "/");
  }

  @override
  int compareTo(String other) {
    if (getAddress() == null) return -1;

    return getAddress()!.compareTo(MessagingAddress(other).getAddress() ?? "");
  }

  @Deprecated(_kErrMsg)
  @override
  String toString() => throw Exception(_kErrMsg);

  /// Instantiate a messaging address object with a path to a Unix Domain
  /// Socket file.
  const MessagingAddress(this._address);
}

/// [EventArgs] for receiving messages from a remote instance. Contains all
/// needed data.
class MessageEventArgs extends EventArgs {
  /// The socket the message was sent from.
  final Socket from;

  /// The [Message] that was sent from the remote instance.
  final Message data;

  MessageEventArgs(this.from, this.data);
}

/// Helps with sending a message and receiving a callback.
class MessageSendOperation {
  final MessagingPipe pipeRef;
  final List<int>? sendToUUID;
  final MessagingAddress sendToAddress;
  bool get requiresCallback => sendToUUID != null;

  /// Wait for a callback to reply to this message.
  Future<Message> waitForCallback() async {
    assert(requiresCallback, "Function 'waitForCallback()' was invoked but 'requiresCallback' returned false!");

    Message receivedCallback = await _doWaitForCallback(sendToAddress, Duration(seconds: 2));

    return receivedCallback;
  }

  Future<Message> _doWaitForCallback(MessagingAddress address, Duration timeout) async {
    final completer = Completer<Message?>();

    pipeRef.receive(address.getAddress() ?? "", (p0) async {
      if (p0!.data.type != MessageType.callbackReply || p0.data.callbackUUID != sendToUUID) return;

      // A callback was received
      completer.complete(p0.data);
    }, true);

    Timer? timeoutTimer;
    timeoutTimer = Timer(timeout, () {
      if (!completer.isCompleted) {
        // Timeout occurred
        completer.complete(null);
      }
      timeoutTimer!.cancel();
    });

    var finalResult = await completer.future;

    return finalResult ?? Message.callbackReply(sendToUUID, {"ErrorMessage": (0x01).toString()}, callbackReplyType: MessageCallbackReplyType.error());
  }

  MessageSendOperation({
    required this.pipeRef,
    required this.sendToAddress,
    this.sendToUUID,
  });
}
