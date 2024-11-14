//  JappeOS-Messaging, A pipe messaging system for JappeOS/Linux.
//  Copyright (C) 2024  Jappe02
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
import 'package:jappeos_messaging/message.dart';

/// A class that manages a messaging pipe, which allows communication between a server
/// and connected clients over a network. It handles establishing connections, 
/// sending and receiving messages, and managing connected clients.
///
/// The `MessagingPipe` class serves as a server that listens for client connections, 
/// processes incoming data, and sends responses back to clients. It also manages 
/// the lifecycle of the server, including initializing and disposing of resources.
///
/// Key features:
/// - Creating a messaging pipe server and listening for incoming client connections.
/// - Handling client connections, including receiving and processing messages.
/// - Managing client disconnections and broadcasting related events.
/// - Gracefully shutting down the server and disconnecting all clients.
///
/// ## Lifecycle:
/// - Use the `create` method to create and initialize a new messaging pipe.
/// - Once the pipe is no longer needed, use the `destroy` method to stop listening
///   for data and release all resources.
///
/// Example usage:
/// ```dart
/// // Create and start listening for incoming client connections.
/// var pipe = await MessagingPipe.create(InternetAddressType.IPv4, 'MyPipe', '127.0.0.1');
///
/// // Send or receive messages here.
///
/// // After finishing work, dispose of the pipe.
/// await MessagingPipe.destroy(pipe);
/// ```
class MessagingPipe {
  static const Message helloMessage = Message(0);

  /// Creates a new messaging pipe instance and starts listening for incoming data.
  ///
  /// This function initializes a `MessagingPipe` instance with the specified parameters 
  /// (such as the address type, name, and address), and then sets up the server to start listening 
  /// for client connections. It must be called to initialize and start the pipe for messaging.
  ///
  /// @param [type] The `InternetAddressType` that specifies the type of IP address (e.g., IPv4, IPv6).
  /// @param [name] A string representing the name of the messaging pipe or service. This could be a 
  ///               human-readable identifier or a service name.
  /// @param [address] The address (IP address or hostname) that the pipe will bind to. This is where 
  ///                  the server will listen for incoming connections.
  /// @param [port] The port that the pipe will bind to. This is where 
  ///               the server will listen for incoming connections.
  ///
  /// @returns A `MessagingPipe` instance that is fully initialized and ready to handle connections.
  /// 
  /// @throws [SocketException] if there is an error binding the server socket (e.g., if the address 
  ///                           is unavailable or in use).
  /// @throws [OSError] if there is a low-level OS error during the socket operations.
  /// 
  /// Example:
  /// ```dart
  /// try {
  ///   var pipe = await MessagingPipe.create(InternetAddressType.IPv4, 'MyPipe', '127.0.0.1', 8080);
  ///   print('Messaging pipe created and listening.');
  /// } catch (e) {
  ///   print('Error creating messaging pipe: $e');
  /// }
  /// ```
  static Future<MessagingPipe> create(InternetAddressType type, String name, String address, int port) async {
    var pipe = MessagingPipe._(type, name, address, port);
    await pipe._initialize();
    return pipe;  
  }

  /// Stops the messaging pipe from listening for data and releases all associated resources.
  ///
  /// This function shuts down the messaging pipe by canceling the server socket's listening behavior, 
  /// disconnecting all clients, and performing any necessary cleanup. It should be called when the 
  /// pipe is no longer needed, such as when the server is being shut down or the pipe is being destroyed.
  ///
  /// @param [pipe] The `MessagingPipe` instance to stop and dispose of.
  ///
  /// @throws [SocketException] if there is an error during the disposal process (e.g., if sockets cannot
  ///                           be closed properly or there are errors with client disconnections).
  /// @throws [OSError] if a low-level OS error occurs while releasing resources.
  ///
  /// Example:
  /// ```dart
  /// try {
  ///   await MessagingPipe.destroy(pipe);
  ///   print('Messaging pipe stopped and resources released.');
  /// } catch (e) {
  ///   print('Error stopping messaging pipe: $e');
  /// }
  /// ```
  static Future<void> destroy(MessagingPipe pipe) async {
    await pipe._dispose();
  }

  /// A private constructor that calls the private [_initialize] function.
  MessagingPipe._(this.type, this.name, this.address, this.port) { _initialize(); }

  /// The [InternetAddressType] to use for communication.
  final InternetAddressType type;

  /// The name of this communication pipe.
  final String name;

  /// The address of this communication pipe.
  final String address;

  /// The port of this communication pipe.
  final int port;

  /// An [Event] called when a client connects to this messaging pipe.
  final Event onClientConnect = Event<Value<Socket>>();

  /// An [Event] called when a client sends a [Message] to this messaging pipe.
  final Event onDataReceive = Event<Values<Socket, Message>>();

  /// An [Event] called when this pipe sends a [Message] to a client.
  final Event onDataSend = Event<Values<Socket, Message>>();

  /// An [Event] called when a client disconnects from this messaging pipe.
  final Event onClientDisconnect = Event<Value<Socket>>();

  /// The server of this messaging pipe.
  late ServerSocket _serverSocket;

  /// The servers [StreamSubscription] that listens to data from clients.
  late StreamSubscription<Socket>? _serverListenerSubscription;

  /// Holds a list of clients connected to this instance.
  ///
  /// [Socket] is the socket that connected to this instance.
  ///
  /// [String] is the address of the socket which connected to this instance.
  final Map<Socket, String> _clientsConnected = {};

  /// Holds a list of accepted clients of this instance.
  /// A client is considered "accepted" when they have sent a hello message.
  final List<Socket> _clientsAccepted = [];

  /// Holds a list of clients this instance is connected to.
  ///
  /// [Socket] is the socket this intance is connected to.
  ///
  /// [String] is the address this instance is connected to.
  final Map<Socket, InternetAddress> _connectedTo = {};

  /// Sends a serialized message to the specified client socket.
  ///
  /// Throws an exception if the client socket is not in the list of accepted clients or if
  /// an error occurs while writing to the socket.
  ///
  /// @throws [StateError] if the client socket is not in `_clientsAccepted`.
  /// @throws [SocketException] if there is a problem with the socket connection during write or flush.
  /// @throws [OSError] if there is a low-level OS error during socket operations.
  ///
  /// Example:
  /// ```dart
  /// try {
  ///   await send(client, message);
  /// } catch (e) {
  ///   print('Failed to send message: $e');
  /// }
  /// ```
  Future<void> send(Socket client, Message message) async {
    if (!_clientsAccepted.contains(client)) {
      throw StateError("Client is not connected.");
    }

    final msg = Message.serialize(message);
    client.write(msg);
    await client.flush();
    onDataSend.broadcast(Values(client, message));
  }

  /// Connects this messaging pipe instance to another instance at the specified address and port.
  ///
  /// Attempts to establish a connection within a 5-second timeout period. If successful, sends
  /// an initial "hello" message and returns the connected [Socket].
  ///
  /// @throws [SocketException] if the connection fails due to network issues.
  /// @throws [TimeoutException] if the connection attempt times out after 5 seconds.
  /// @throws [OSError] if there is a low-level OS error during connection.
  ///
  /// Returns a [Socket] instance representing the connection to the specified address.
  ///
  /// Example:
  /// ```dart
  /// try {
  ///   var socket = await connectTo('localhost', 8080);
  ///   print('Connected to server at ${socket.remoteAddress}:${socket.remotePort}');
  /// } catch (e) {
  ///   print('Connection failed: $e');
  /// }
  /// ```
  Future<Socket> connectTo(String address, int port) async {
    var socket = await Socket.connect(address, port, timeout: Duration(seconds: 5));
    _connectedTo[socket] = socket.address;

    // Send initial "hello" message and await to ensure completion before returning
    await send(socket, Message(0));

    return socket;
  }

  /// Disconnects this messaging pipe instance from the specified socket.
  ///
  /// If the socket is not currently connected (i.e., not found in `_connectedTo`), this method does nothing.
  /// If connected, this method flushes any remaining data, closes the socket, and removes it from `_connectedTo`.
  ///
  /// @throws [SocketException] if an error occurs while flushing or closing the socket.
  /// @throws [OSError] if a low-level OS error occurs during socket operations.
  ///
  /// Example:
  /// ```dart
  /// try {
  ///   await disconnectFrom(socket);
  ///   print('Disconnected from ${socket.remoteAddress}:${socket.remotePort}');
  /// } catch (e) {
  ///   print('Error disconnecting: $e');
  /// }
  /// ```
  Future<void> disconnectFrom(Socket socket) async {
    if (!_connectedTo.containsKey(socket)) {
      return; // No action if socket is not in `_connectedTo`
    }

    await socket.flush();  // Ensure any pending data is sent before closing
    await socket.close();  // Close the socket connection
    _connectedTo.remove(socket);  // Remove from connected clients
  }

  /// Get the clients currently connected to this messaging pipe.
  List<Socket> getConnectedClients() => UnmodifiableListView(_clientsAccepted);

  /// Get the clients this messaging pipe is currently connected to.
  List<Socket> getConnections() => UnmodifiableListView(_connectedTo.keys);

  /// Initializes the server socket and sets up listeners for incoming client connections.
  ///
  /// Binds to the specified port at the specified address and listens for new client connections.
  /// For each client, it:
  ///   - Sets up a data listener to process incoming messages.
  ///   - Manages client connection and disconnection events.
  ///   - Waits for an initial "hello" message from each client for validation.
  ///
  /// This method is intended to be called once to start the server socket. 
  ///
  /// @throws [SocketException] if there is an error binding the server socket or in client communication.
  /// @throws [OSError] if a low-level OS error occurs during socket operations.
  Future<void> _initialize() async {
    // Bind the server socket to the specified address and any available port
    _serverSocket = await ServerSocket.bind(address, 0);

    // Listen for incoming client connections
    _serverListenerSubscription = _serverSocket.listen((clientSocket) async {
      // Manage each client's data and lifecycle
      StreamSubscription<Uint8List>? clientSubscription;
      final onClientData = Event<Value<Uint8List>>();

      try {
        // Listen for data from the client and handle disconnection
        clientSubscription = clientSocket.listen(
          (data) async {
            onClientData.broadcast(Value(data));
            _handleClientData(clientSocket, data);
          },
          onDone: () async {
            // Cleanup when the client disconnects
            await clientSubscription?.cancel();
            _handleClientDisconnection(clientSocket);
          },
        );

        // Wait for an initial "hello" message from the client
        if (!await _handleClientHelloMessage(clientSocket, onClientData)) {
          await clientSocket.close();
        }

        onClientData.unsubscribeAll();

        // Only proceed if the client has been accepted
        if (!_clientsConnected.containsKey(clientSocket)) {
          return;
        }

        // Handle client acceptance and final setup
        _handleClientAcception(clientSocket);
      } catch (e) {
        print("Error handling client connection: $e");
        await clientSocket.close();
      }
    });
  }

  /// Disposes of this server instance, closing the server socket, disconnecting all clients, 
  /// and cleaning up all subscriptions and resources.
  ///
  /// This method ensures that all client sockets are flushed and closed, 
  /// and any event listeners or subscriptions are cancelled.
  ///
  /// @throws [SocketException] if there is an error while closing sockets or server.
  Future<void> _dispose() async {
    // Stop listening for new connections
    await _serverListenerSubscription?.cancel();
    await _serverSocket.close();

    // Disconnect all connected clients
    for (final client in _clientsConnected.keys.toList()) {
      try {
        await client.flush();
        await client.close();
      } catch (e) {
        print("Error disconnecting client $client: $e");
      }
    }

    // Clear all client references
    _clientsConnected.clear();
    _clientsAccepted.clear();

    // Perform any additional cleanup, if necessary
    print("Server disposed and all clients disconnected.");
  }

  /// Handles the "hello" message from a client to establish initial communication.
  ///
  /// Listens for the "hello" message (identified by `id == 0`) from the client, using an event-based
  /// approach. If the message is not received within 5 seconds, it times out and returns `false`.
  ///
  /// @param [clientSocket] The socket of the connected client.
  /// @param [onDataEventRef] A reference to the event that fires when data is received from the client.
  /// @returns [bool] `true` if the hello message is received within the timeout period, `false` otherwise.
  ///
  /// @throws [FormatException] if there is an issue deserializing the incoming message.
  ///
  /// Example:
  /// ```dart
  /// bool isHelloReceived = await _handleClientHelloMessage(clientSocket, onDataEventRef);
  /// if (isHelloReceived) {
  ///   print('Hello message received from client');
  /// } else {
  ///   print('Hello message timed out');
  /// }
  /// ```
  Future<bool> _handleClientHelloMessage(Socket clientSocket, Event<Value<Uint8List>> onDataEventRef) async {
    final completer = Completer<bool>();
  
    void onDataReceived(Value<Uint8List>? args) {
      try {
        final received = Message.deserialize(args!.value);
        if (received.id == 0) {
          completer.complete(true);
        }
      } catch (e) {
        completer.completeError(e);
      }
    }
  
    // Subscribe to event and listen for a hello message
    onDataEventRef + onDataReceived;
  
    // Set up a 5-second timeout
    Timer? timeoutTimer;
    timeoutTimer = Timer(Duration(seconds: 5), () {
      if (!completer.isCompleted) {
        completer.complete(false);
      }
      timeoutTimer?.cancel();
    });
  
    // Wait for either completion or timeout
    var finalResult = await completer.future.catchError((e) {
      print("Error handling hello message: $e");
      return false;
    });
  
    // Unsubscribe from the event after completion
    onDataEventRef - onDataReceived;
    return finalResult;
  }

  /// Officially accepts a client connection after successful "hello" message verification.
  ///
  /// Adds the client to `_clientsAccepted` and triggers the `onClientConnect` event.
  /// This method assumes the client has successfully connected and passed initial checks.
  ///
  /// @param [clientSocket] The socket of the client being accepted.
  ///
  /// Example:
  /// ```dart
  /// _handleClientAcception(clientSocket);
  /// print('Client accepted.');
  /// ```
  void _handleClientAcception(Socket clientSocket) {
    _clientsAccepted.add(clientSocket);
    onClientConnect.broadcast(Value(clientSocket));
  }

  /// Handles incoming data from accepted clients and broadcasts the received message.
  ///
  /// Deserializes the message and triggers `onDataReceive` event. If the client is not in `_clientsAccepted`,
  /// the data is ignored.
  ///
  /// @param [clientSocket] The socket of the client sending the data.
  /// @param [data] The raw data received from the client.
  ///
  /// Example:
  /// ```dart
  /// _handleClientData(clientSocket, data);
  /// print('Data processed from client.');
  /// ```
  void _handleClientData(Socket clientSocket, Uint8List data) {
    if (!_clientsAccepted.contains(clientSocket)) {
      return; // Ignore data from non-accepted clients
    }

    try {
      final message = Message.deserialize(data);
      onDataReceive.broadcast(Values(clientSocket, message));
    } catch (e) {
      print("Error deserializing message from client: $e");
    }
  }

  /// Handles the disconnection of a client, removing it from tracking and broadcasting the disconnection event.
  ///
  /// If the client is found in `_clientsAccepted`, it is removed and the `onClientDisconnect` event is triggered.
  /// This function should be called whenever a client disconnects.
  ///
  /// @param [clientSocket] The socket of the disconnected client.
  ///
  /// Example:
  /// ```dart
  /// _handleClientDisconnection(clientSocket);
  /// print('Client disconnected.');
  /// ```
  void _handleClientDisconnection(Socket clientSocket) {
    // Remove from the connected clients list
    _clientsConnected.remove(clientSocket);

    // If client was accepted, remove and broadcast the disconnect
    if (_clientsAccepted.contains(clientSocket)) {
      _clientsAccepted.remove(clientSocket);
      onClientDisconnect.broadcast(Value(clientSocket));
    }
  }
}