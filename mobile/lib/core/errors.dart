/// Plain-language sentences for every error code the backend can send.
/// The UI never shows raw codes or HTTP status numbers.
const Map<String, String> friendlyByCode = {
  // Auth / platform
  'UNAUTHENTICATED': 'Your session has ended. Please sign in again.',
  'INVALID_CREDENTIALS': 'That email or password is not correct.',
  'FORBIDDEN': 'Your account is not allowed to do that.',
  'RATE_LIMITED': 'Too many requests at once. Please wait a few seconds and try again.',
  'PAYLOAD_TOO_LARGE': 'That request was too large to send.',
  'VALIDATION_ERROR': 'Some details are missing or not valid. Please check and try again.',
  'NOT_FOUND': 'That item could not be found.',
  // Roster
  'SQUAD_FULL': 'The destination squad is already full, so the player could not join it.',
  'TRANSFER_WINDOW_CLOSED': 'The transfer window is closed on that date. Only releases are allowed outside the window.',
  'MIN_POSITION_VIOLATION': 'This move would leave the squad without enough players in that position.',
  'NOT_IN_SQUAD': 'This player is no longer in that squad. The roster changed on the server.',
  'PLAYER_ON_LOAN': 'This player is currently on loan and cannot be moved until the loan ends.',
  'CROSS_TENANT_TRANSFER': 'Players can only move between clubs of the same organisation.',
  'PLAYER_NOT_FOUND': 'That player could not be found on the server.',
  'SQUAD_NOT_FOUND': 'That squad could not be found on the server.',
  'LEAGUE_NOT_FOUND': 'That league could not be found on the server.',
  'CLUB_NOT_FOUND': 'That club could not be found on the server.',
  // Scoring
  'MATCH_NOT_FOUND': 'That match could not be found on the server.',
  'MATCH_NOT_IN_PROGRESS': 'Scores can only be added while the match is live.',
  'MATCH_EXISTS': 'That match already exists.',
  'ILLEGAL_TRANSITION': 'The match is not in the right state for that action.',
  'TIE_NOT_ALLOWED': 'The match cannot end level in this sport. Record a tie-break winner first.',
  'INVALID_COMPENSATION': 'That event cannot be corrected. It may already be corrected or is not a score event.',
  'EVENT_NOT_FOUND': 'The event to correct could not be found.',
  'DUPLICATE_EVENT_ID': 'This event was already sent with different details.',
  'UNKNOWN_EVENT_TYPE': 'That kind of score is not used in this sport.',
  'INNINGS_COMPLETE': 'That team has finished its innings, so no more scores can be added.',
  'SERIES_ALREADY_DECIDED': 'The series is already decided, so no more rounds can be added.',
  'SPORT_NOT_FOUND': 'That sport could not be found.',
  'INVALID_BASE_VERSION': 'Your saved copy did not match the server, so the server version was kept.',
  // Store
  'OUT_OF_STOCK': 'Sorry, that item just sold out. Please choose another size or reduce the quantity.',
  'PAYMENT_DECLINED': 'Your card was declined. You were not charged. Please try another card.',
  'PAYMENT_CAPTURE_FAILED':
      'The payment could not be completed, so the authorisation was cancelled. You were not charged.',
  'INVALID_DISCOUNT_CODE': 'That discount code is not valid.',
  'VARIANT_NOT_FOUND': 'That product option is no longer available.',
  'DUPLICATE_ORDER_ID': 'This order was already placed with different details. Please start a new checkout.',
  'PRODUCT_NOT_FOUND': 'That product could not be found.',
};

const String offlineMessage =
    "Can't reach the server. You may be offline. Check Wi-Fi or the server address in Settings.";

/// Picks the best sentence to show for an error.
String friendlyMessage({String? code, String? serverMessage, int? status}) {
  if (code != null && friendlyByCode.containsKey(code)) return friendlyByCode[code]!;
  if (status != null && status >= 500) {
    return 'The server had a problem. Please try again in a moment.';
  }
  if (status == 401) return friendlyByCode['UNAUTHENTICATED']!;
  if (status == 403) return friendlyByCode['FORBIDDEN']!;
  if (status == 404) return 'That item could not be found. The server may not offer it yet.';
  if (status == 429) return friendlyByCode['RATE_LIMITED']!;
  final msg = serverMessage?.trim();
  if (msg != null && msg.isNotEmpty && !RegExp(r'^[A-Z_]+$').hasMatch(msg)) return msg;
  return 'Something went wrong. Please try again.';
}
