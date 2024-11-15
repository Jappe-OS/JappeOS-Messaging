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
import 'dart:io';

import 'package:event/event.dart';
import 'package:jappeos_messaging/events.dart';
import 'package:jappeos_messaging/message.dart';

/// A class that facilitates communication over a messaging pipe using the UDP protocol.
///
/// The `MessagingPipe` class serves as a lightweight, stateless communication mechanism 
/// for sending and receiving messages over a network. It operates without maintaining 
/// persistent client connections, relying instead on the UDP protocol's datagram-based 
/// communication.
///
/// Key features:
/// - Sending and receiving messages over a network using UDP.
/// - Handling incoming datagrams and broadcasting related events.
/// - Gracefully initializing and disposing of the server socket.
///
/// ## Lifecycle:
/// - Use the `create` method to create and initialize a new messaging pipe.
/// - The pipe listens for incoming datagrams and processes them independently.
/// - Once the pipe is no longer needed, use the `destroy` method to stop listening 
///   for data and release all resources.
///
/// ## Key Considerations:
/// - As UDP is connectionless, the class does not track clients. Instead, messages 
///   include sender information (IP and port) that can be used for replies.
/// - Message delivery, ordering, and integrity are not guaranteed and must be 
///   handled by the application if required.
/// - UDP supports broadcasting and multicast, making it suitable for use cases 
///   like discovery or one-to-many communication.
///
/// Example usage:
/// ```dart
/// // Create and start the messaging pipe.
/// var pipe = await MessagingPipe.create(InternetAddressType.IPv4, 'MyPipe', '127.0.0.1', 8080);
///
/// // The pipe will handle incoming messages and can send responses as needed.
///
/// // After finishing work, dispose of the pipe.
/// await MessagingPipe.destroy(pipe);
/// ```
class MessagingPipe {
  /// Creates a new messaging pipe instance and starts listening for incoming UDP datagrams.
  ///
  /// This function initializes a `MessagingPipe` instance with the specified parameters 
  /// (such as the address type, name, and address) and sets up a UDP socket to start listening 
  /// for incoming messages. It must be called to initialize and start the pipe for messaging.
  ///
  /// @param [type] The `InternetAddressType` that specifies the type of IP address (e.g., IPv4, IPv6).
  /// @param [name] A string representing the name of the messaging pipe or service. This could be a 
  ///               human-readable identifier or a service name.
  /// @param [address] The address (IP address or hostname) that the pipe will bind to. This is where 
  ///                  the server will listen for incoming datagrams.
  /// @param [port] The port that the pipe will bind to. This is where the server will listen for incoming datagrams.
  ///
  /// @returns A `MessagingPipe` instance that is fully initialized and ready to handle incoming messages.
  /// 
  /// @throws [SocketException] if there is an error binding the UDP socket (e.g., if the address 
  ///                           is unavailable or in use).
  /// @throws [OSError] if there is a low-level OS error during socket operations.
  /// 
  /// ## Example:
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
  /// This function shuts down the UDP socket associated with the messaging pipe, 
  /// stopping it from receiving further datagrams and releasing any system resources. 
  /// It should be called when the messaging pipe is no longer needed, such as during application shutdown.
  ///
  /// @param [pipe] The `MessagingPipe` instance to stop and dispose of.
  ///
  /// @throws [SocketException] if there is an error during the disposal process (e.g., if the socket 
  ///                           cannot be closed properly).
  /// @throws [OSError] if a low-level OS error occurs while releasing resources.
  ///
  /// ## Example:
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

  /// An [Event] called when a client sends a [Message] to this messaging pipe.
  final Event onDataReceive = Event<MessageReceivedEventArgs>();

  /// An [Event] called when this pipe sends a [Message] to a client.
  final Event onDataSend = Event<MessageSentEventArgs>();

  /// The socket of this messaging pipe.
  late RawDatagramSocket _socket;

  /// Sends a serialized message to the specified destination address and port.
  ///
  /// This function sends a message as a UDP datagram to the specified recipient. 
  /// It does not require maintaining a persistent connection and is suitable for 
  /// stateless communication.
  ///
  /// @param [destination] The `InternetAddress` of the recipient.
  /// @param [port] The port number of the recipient.
  /// @param [message] The message to be sent, which should already be serialized (e.g., as a string or bytes).
  ///
  /// @throws [SocketException] if there is an issue sending the datagram (e.g., network errors or invalid address).
  /// @throws [OSError] if there is a low-level OS error during the UDP operation.
  ///
  /// ## Example:
  /// ```dart
  /// try {
  ///   await pipe.send(InternetAddress('127.0.0.1'), 8080, 'Hello, World!');
  ///   print('Message sent successfully.');
  /// } catch (e) {
  ///   print('Failed to send message: $e');
  /// }
  /// ```
  Future<void> send(InternetAddress targetAddress, int targetPort, Message message) async {
    var serializedMessage = Message.serialize(message);
    _socket.send(serializedMessage, targetAddress, targetPort);
    onDataSend.broadcast(MessageSentEventArgs(targetAddress, targetPort, message));
    print('Message sent to $targetAddress:$targetPort');
  }

  /// Initializes the server socket to start listening for incoming UDP messages.
  ///
  /// This method binds to the specified address and port, setting up the server to handle 
  /// incoming UDP datagrams. It prepares the server to process messages asynchronously 
  /// without maintaining persistent client connections.
  ///
  /// This method is intended to be called once to start the UDP server.
  ///
  /// @throws [SocketException] if there is an error binding the server socket to the specified address and port.
  /// @throws [OSError] if a low-level OS error occurs during socket operations.
  ///
  /// ## Example:
  /// ```dart
  /// await _initialize(InternetAddressType.IPv4, '127.0.0.1', 8080);
  /// print('Server initialized and ready to receive messages.');
  /// ```
  Future<void> _initialize() async {
    _socket = await RawDatagramSocket.bind(
      InternetAddress(address, type: type),
      port,
    );
    _socket.listen(_handleIncomingData);
    print('UDP MessagingPipe initialized at $address:$port');
  }

  /// Shuts down the server socket and releases all associated resources.
  ///
  /// This method ensures that the server socket is properly closed, cancelling any active
  /// operations and cleaning up resources. It stops the server from receiving further 
  /// UDP messages and finalizes any pending tasks.
  ///
  /// This method is intended to be called when the server is no longer needed.
  ///
  /// @throws [SocketException] if there is an error while closing the socket.
  /// @throws [OSError] if a low-level OS error occurs during resource cleanup.
  ///
  /// ## Example:
  /// ```dart
  /// await _dispose();
  /// print('Server disposed and resources released.');
  /// ```
  Future<void> _dispose() async {
    _socket.close();
    print('UDP MessagingPipe disposed.');
  }

  /// Handles incoming UDP data and processes messages.
  void _handleIncomingData(RawSocketEvent event) {
    if (event == RawSocketEvent.read) {
      Datagram? datagram = _socket.receive();
      if (datagram != null) {
        try {
          var message = Message.deserialize(datagram.data);
          onDataReceive.broadcast(MessageReceivedEventArgs(datagram.address, datagram.port, message));
          print('Message received from ${datagram.address}:${datagram.port}: ${message.id}');
        } catch (e) {
          print('Failed to process incoming message: $e');
        }
      }
    }
  }
}