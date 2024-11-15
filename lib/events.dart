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

import 'dart:io';

import 'package:event/event.dart';
import 'package:jappeos_messaging/message.dart';

class MessageSentEventArgs extends EventArgs {
  MessageSentEventArgs(this.address, this.port, this.sentMessage);

  final InternetAddress address;
  final int port;
  final Message sentMessage;
}

class MessageReceivedEventArgs extends EventArgs {
  MessageReceivedEventArgs(this.address, this.port, this.sentMessage);

  final InternetAddress address;
  final int port;
  final Message sentMessage;
}