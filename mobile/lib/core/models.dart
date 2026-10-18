import 'format.dart';

class Roles {
  static const superAdmin = 'super_admin';
  static const organizer = 'league_organizer';
  static const manager = 'club_manager';
  static const player = 'player';
  static const viewer = 'viewer';

  static String label(String role) => switch (role) {
    superAdmin => 'Platform admin',
    organizer => 'League organizer',
    manager => 'Club manager',
    player => 'Player',
    viewer => 'Viewer',
    _ => humanize(role),
  };
}

class AppUser {
  const AppUser({
    required this.userId,
    required this.email,
    required this.role,
    this.displayName,
    this.tenantId,
    this.leagueId,
    this.clubId,
    this.playerId,
  });

  final String userId;
  final String email;
  final String role;
  final String? displayName;
  final String? tenantId;
  final String? leagueId;
  final String? clubId;
  final String? playerId;

  String get name => (displayName != null && displayName!.isNotEmpty) ? displayName! : email;
  bool get canScore => role == Roles.organizer || role == Roles.superAdmin;
  bool get canManageRoster => role == Roles.manager || role == Roles.superAdmin;

  bool canManageClub(String clubId) => role == Roles.superAdmin || (role == Roles.manager && this.clubId == clubId);

  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
    userId: asStr(j['user_id'] ?? j['sub'] ?? j['id']),
    email: asStr(j['email']),
    role: asStr(j['role'], Roles.viewer),
    displayName: j['display_name'] as String?,
    tenantId: j['tenant_id'] as String?,
    leagueId: j['league_id'] as String?,
    clubId: j['club_id'] as String?,
    playerId: j['player_id'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'user_id': userId,
    'email': email,
    'role': role,
    'display_name': displayName,
    'tenant_id': tenantId,
    'league_id': leagueId,
    'club_id': clubId,
    'player_id': playerId,
  };
}

class Tenant {
  const Tenant({required this.tenantId, required this.name, this.logoUrl, this.primaryColor, this.secondaryColor});

  final String tenantId;
  final String name;
  final String? logoUrl;
  final String? primaryColor;
  final String? secondaryColor;

  factory Tenant.fromJson(Map<String, dynamic> j) => Tenant(
    tenantId: asStr(j['tenant_id']),
    name: asStr(j['name'], 'League'),
    logoUrl: j['logo_url'] as String?,
    primaryColor: j['primary_color'] as String?,
    secondaryColor: j['secondary_color'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'tenant_id': tenantId,
    'name': name,
    'logo_url': logoUrl,
    'primary_color': primaryColor,
    'secondary_color': secondaryColor,
  };
}

class Session {
  const Session({required this.token, required this.user, this.tenant});

  final String token;
  final AppUser user;
  final Tenant? tenant;

  factory Session.fromJson(Map<String, dynamic> j) => Session(
    token: asStr(j['token']),
    user: AppUser.fromJson(asMap(j['user'])),
    tenant: j['tenant'] is Map ? Tenant.fromJson(asMap(j['tenant'])) : null,
  );

  Map<String, dynamic> toJson() => {'token': token, 'user': user.toJson(), 'tenant': tenant?.toJson()};
}

class ActionTypes {
  static const scoreEvent = 'score_event';
  static const rosterTransfer = 'roster_transfer';
}

/// One queued offline action, in exactly the Section 5.14 format.
/// [label] is local-only (what the user did, in words) and never sent.
class PendingAction {
  const PendingAction({
    required this.actionId,
    required this.type,
    required this.queuedAt,
    required this.baseVersion,
    required this.payload,
    this.label = '',
    this.owner = '',
  });

  final String actionId;
  final String type;
  final String queuedAt;
  final int baseVersion;
  final Map<String, dynamic> payload;
  final String label;

  /// user_id of the account that queued it: only that account sees and syncs it (with its own token).
  final String owner;

  /// Match id (score_event) or player id (roster_transfer) this action touches.
  String get targetId => type == ActionTypes.scoreEvent ? asStr(payload['match_id']) : asStr(payload['player_id']);

  Map<String, dynamic> toJson() => {
    'action_id': actionId,
    'type': type,
    'queued_at': queuedAt,
    'base_version': baseVersion,
    'payload': payload,
  };

  factory PendingAction.fromJson(Map<String, dynamic> j, {String label = ''}) => PendingAction(
    actionId: asStr(j['action_id']),
    type: asStr(j['type']),
    queuedAt: asStr(j['queued_at']),
    baseVersion: asInt(j['base_version']),
    payload: asMap(j['payload']),
    label: label,
  );
}

/// Builds the POST /sync (5.14) request body.
Map<String, dynamic> buildSyncRequest(String deviceId, List<PendingAction> actions) => {
  'device_id': deviceId,
  'actions': [for (final a in actions) a.toJson()],
};

/// One line of the "last sync results" log.
class SyncLogEntry {
  const SyncLogEntry({
    required this.actionId,
    required this.label,
    required this.status,
    required this.message,
    required this.at,
    this.resolution,
    this.errorCode,
    this.owner = '',
  });

  final String actionId;
  final String label;
  final String owner; // user_id whose action this was
  final String status; // applied | rejected | duplicate
  final String? resolution;
  final String? errorCode;
  final String message;
  final String at;

  Map<String, dynamic> toJson() => {
    'action_id': actionId,
    'label': label,
    'status': status,
    'resolution': resolution,
    'error_code': errorCode,
    'message': message,
    'at': at,
    'owner': owner,
  };

  factory SyncLogEntry.fromJson(Map<String, dynamic> j) => SyncLogEntry(
    actionId: asStr(j['action_id']),
    label: asStr(j['label']),
    status: asStr(j['status']),
    resolution: j['resolution'] as String?,
    errorCode: j['error_code'] as String?,
    message: asStr(j['message']),
    at: asStr(j['at']),
    owner: asStr(j['owner']),
  );
}
