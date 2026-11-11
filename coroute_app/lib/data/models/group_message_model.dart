import '../../domain/ride/ride_chat.dart';

class GroupMessageModel {
  final String messageId;
  final String senderId;
  final String senderName;
  final String text;
  final int timestamp;
  final bool isQuickCard;
  final String cardType; // 'FUEL', 'WAIT_2MIN', 'REGROUP', 'MECHANICAL', 'CUSTOM'

  /// Gateway cards (senderId 'SYSTEM', e.g. "Wait for me"): the rider who asked ('' otherwise).
  final String requestedBy;

  GroupMessageModel({
    required this.messageId,
    required this.senderId,
    required this.senderName,
    required this.text,
    required this.timestamp,
    this.isQuickCard = false,
    this.cardType = 'CUSTOM',
    this.requestedBy = '',
  });

  /// The rider behind the message (the requester for a SYSTEM card).
  String get authorId => (senderId == 'SYSTEM' && requestedBy.isNotEmpty) ? requestedBy : senderId;

  /// The pure view used by the chat rules (lib/domain/ride/ride_chat.dart).
  ChatLine toLine() => ChatLine(
        id: messageId,
        senderId: senderId,
        senderName: senderName,
        text: text,
        timestamp: timestamp,
        isQuickCard: isQuickCard,
        cardType: cardType,
        requestedBy: requestedBy,
      );

  Map<String, dynamic> toJson() => {
        'messageId': messageId,
        'senderId': senderId,
        'senderName': senderName,
        'text': text,
        'timestamp': timestamp,
        'isQuickCard': isQuickCard,
        'cardType': cardType,
        if (requestedBy.isNotEmpty) 'requestedBy': requestedBy,
      };

  factory GroupMessageModel.fromJson(Map<String, dynamic> json) =>
      GroupMessageModel(
        messageId: json['messageId'] ?? '',
        senderId: json['senderId'] ?? '',
        senderName: json['senderName'] ?? '',
        text: json['text'] ?? '',
        timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
        isQuickCard: json['isQuickCard'] ?? false,
        cardType: json['cardType'] ?? 'CUSTOM',
        requestedBy: json['requestedBy']?.toString() ?? '',
      );
}
