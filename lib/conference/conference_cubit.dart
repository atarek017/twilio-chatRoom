import 'dart:async';
import 'package:bloc/bloc.dart';
import 'package:collection/collection.dart' show IterableExtension;
import 'package:flutter/material.dart';

import 'package:equatable/equatable.dart';
import 'package:twilio_programmable_video/twilio_programmable_video.dart';
import 'package:twillo/conference/participant_widget.dart';
import 'package:uuid/uuid.dart';

abstract class ConferenceState extends Equatable {
  const ConferenceState();

  @override
  List<Object> get props => [];
}

class ConferenceInitial extends ConferenceState {}

class ConferenceLoaded extends ConferenceState {}

class ConferenceCubit extends Cubit<ConferenceState> {
  final String name;
  final String token;
  final String identity;
  final List<ParticipantWidget> _participants = [];
  var trackId;

  late Room _room;
  late VideoCapturer _cameraCapturer;
  late List<StreamSubscription> _streamSubscriptions = [];

  ConferenceCubit({
    required this.name,
    required this.token,
    required this.identity,
  }) : super(ConferenceInitial()) {
    connect();
  }

  List<ParticipantWidget> get participants {
    return [..._participants];
  }

  ParticipantWidget _buildParticipant({
    required Widget child,
    required String? id,
  }) {
    return ParticipantWidget(
      id: id,
      child: child,
    );
  }

  connect() async {
    print('[ APPDEBUG ] ConferenceRoom.connect()');
    try {
      await TwilioProgrammableVideo.setAudioSettings(speakerphoneEnabled: true, bluetoothPreferred: true);

      final sources = await CameraSource.getSources();
      _cameraCapturer = CameraCapturer(
        sources.firstWhere((source) => source.isFrontFacing),
      );

      trackId = const Uuid().v4();

      var connectOptions = ConnectOptions(
        token,
        roomName: name,
        preferredAudioCodecs: [OpusCodec()],
        audioTracks: [LocalAudioTrack(true, 'audio_track-$trackId')],
        dataTracks: [
          LocalDataTrack(
            DataTrackOptions(name: 'data_track-$trackId'),
          )
        ],
        videoTracks: [LocalVideoTrack(true, _cameraCapturer)],
        enableNetworkQuality: true,
        networkQualityConfiguration: NetworkQualityConfiguration(
          remote: NetworkQualityVerbosity.NETWORK_QUALITY_VERBOSITY_MINIMAL,
        ),
        enableDominantSpeaker: true,
      );

      _room = await TwilioProgrammableVideo.connect(connectOptions);

      _streamSubscriptions.add(_room.onConnected.listen(_onConnected));
      _streamSubscriptions.add(_room.onDisconnected.listen(_onDisconnected));
      _streamSubscriptions.add(_room.onReconnecting.listen(_onReconnecting));
      _streamSubscriptions.add(_room.onConnectFailure.listen(_onConnectFailure));
    } catch (err) {
      print('[ APPDEBUG ] $err');
      rethrow;
    }
  }

  Future<void> disconnect() async {
    print('[ APPDEBUG ] ConferenceRoom.disconnect()');
    await _room.disconnect();
  }

  void _onDisconnected(RoomDisconnectedEvent event) {
    print('[ APPDEBUG ] ConferenceRoom._onDisconnected');
  }

  void _onReconnecting(RoomReconnectingEvent room) {
    print('[ APPDEBUG ] ConferenceRoom._onReconnecting');
  }

  void _onConnected(Room room) {
    print('[ APPDEBUG ] ConferenceRoom._onConnected => state: ${room.state}');

    // When connected for the first time, add remote participant listeners
    _streamSubscriptions
        .add(_room.onParticipantConnected.listen(_onParticipantConnected));
    _streamSubscriptions.add(
        _room.onParticipantDisconnected.listen(_onParticipantDisconnected));
    final localParticipant = room.localParticipant;
    if (localParticipant == null) {
      print(
          '[ APPDEBUG ] ConferenceRoom._onConnected => localParticipant is null');
      return;
    }

    // Only add ourselves when connected for the first time too.
    _participants.add(_buildParticipant(
        child: localParticipant.localVideoTracks[0].localVideoTrack.widget(),
        id: identity));

    for (final remoteParticipant in room.remoteParticipants) {
      var participant = _participants.firstWhereOrNull(
          (participant) => participant.id == remoteParticipant.sid);
      if (participant == null) {
        print(
            '[ APPDEBUG ] Adding participant that was already present in the room ${remoteParticipant.sid}, before I connected');
        _addRemoteParticipantListeners(remoteParticipant);
      }
    }
    reload();
  }

  void _onConnectFailure(RoomConnectFailureEvent event) {
    print('[ APPDEBUG ] ConferenceRoom._onConnectFailure: ${event.exception}');
  }

  void _onParticipantConnected(RoomParticipantConnectedEvent event) {
    print(
        '[ APPDEBUG ] ConferenceRoom._onParticipantConnected, ${event.remoteParticipant.sid}');
    _addRemoteParticipantListeners(event.remoteParticipant);
    reload();
  }

  void _onParticipantDisconnected(RoomParticipantDisconnectedEvent event) {
    print(
        '[ APPDEBUG ] ConferenceRoom._onParticipantDisconnected: ${event.remoteParticipant.sid}');
    _participants.removeWhere(
        (ParticipantWidget p) => p.id == event.remoteParticipant.sid);
    reload();
  }

  void _addRemoteParticipantListeners(RemoteParticipant remoteParticipant) {
    _streamSubscriptions.add(remoteParticipant.onVideoTrackSubscribed
        .listen(_addOrUpdateParticipant));
    _streamSubscriptions.add(remoteParticipant.onAudioTrackSubscribed
        .listen(_addOrUpdateParticipant));
  }

  void _addOrUpdateParticipant(RemoteParticipantEvent event) {
    print(
        '[ APPDEBUG ] ConferenceRoom._addOrUpdateParticipant(), ${event.remoteParticipant.sid}');
    final participant = _participants.firstWhereOrNull(
      (ParticipantWidget participant) =>
          participant.id == event.remoteParticipant.sid,
    );

    if (participant != null) {
      print(
          '[ APPDEBUG ] Participant found: ${participant.id}, updating A/V enabled values');
    } else {
      if (event is RemoteVideoTrackSubscriptionEvent) {
        print(
            '[ APPDEBUG ] New participant, adding: ${event.remoteParticipant.sid}');
        _participants.insert(
          0,
          _buildParticipant(
            child: event.remoteVideoTrack.widget(),
            id: event.remoteParticipant.sid,
          ),
        );
        reload();
      }
    }
  }

  reload() {
    emit(ConferenceInitial());
    emit(ConferenceLoaded());
  }
}
