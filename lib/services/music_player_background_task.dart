import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:android_id/android_id.dart';
import 'package:audio_service/audio_service.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:finamp/services/locale_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logging/logging.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

import '../models/finamp_models.dart';
import '../models/jellyfin_models.dart';
import 'finamp_settings_helper.dart';
import 'finamp_user_helper.dart';
import 'jellyfin_api_helper.dart';
import 'media_item_helper.dart';

/// This provider handles the currently playing music so that multiple widgets
/// can control music.
class MusicPlayerBackgroundTask extends BaseAudioHandler {
  final _player = AudioPlayer(
    audioLoadConfiguration: AudioLoadConfiguration(
        androidLoadControl: AndroidLoadControl(
          minBufferDuration: FinampSettingsHelper.finampSettings.bufferDuration,
          maxBufferDuration: FinampSettingsHelper.finampSettings.bufferDuration,
          prioritizeTimeOverSizeThresholds: true,
        ),
        darwinLoadControl: DarwinLoadControl(
          preferredForwardBufferDuration:
              FinampSettingsHelper.finampSettings.bufferDuration,
        )),
  );
  ConcatenatingAudioSource _queueAudioSource =
      ConcatenatingAudioSource(children: []);
  final _audioServiceBackgroundTaskLogger = Logger("MusicPlayerBackgroundTask");
  final _jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
  final _finampUserHelper = GetIt.instance<FinampUserHelper>();
  final _mediaItemHelper = GetIt.instance<MediaItemHelper>();

  /// Set when shuffle mode is changed. If true, [onUpdateQueue] will create a
  /// shuffled [ConcatenatingAudioSource].
  bool shuffleNextQueue = false;

  /// Set when creating a new queue. Will be used to set the first index in a
  /// new queue.
  int? nextInitialIndex;

  /// The item that was previously played. Used for reporting playback status.
  MediaItem? _previousItem;

  /// Set to true when we're stopping the audio service. Used to avoid playback
  /// progress reporting.
  bool _isStopping = false;

  /// Holds the current sleep timer, if any. This is a ValueNotifier so that
  /// widgets like SleepTimerButton can update when the sleep timer is/isn't
  /// null.
  bool _sleepTimerIsSet = false;
  Duration _sleepTimerDuration = Duration.zero;
  final ValueNotifier<Timer?> _sleepTimer = ValueNotifier<Timer?>(null);

  List<int>? get shuffleIndices => _player.shuffleIndices;

  ValueListenable<Timer?> get sleepTimer => _sleepTimer;

  MusicPlayerBackgroundTask() {
    _audioServiceBackgroundTaskLogger.info("Starting audio service");

    // Propagate all events from the audio player to AudioService clients.
    _player.playbackEventStream.listen((event) async {
      playbackState.add(_transformEvent(event));

      if (playbackState.valueOrNull != null &&
          playbackState.valueOrNull?.processingState !=
              AudioProcessingState.idle &&
          playbackState.valueOrNull?.processingState !=
              AudioProcessingState.completed &&
          !FinampSettingsHelper.finampSettings.isOffline &&
          !_isStopping) {
        await _updatePlaybackProgress();
      }
    });

    // Special processing for state transitions.
    _player.processingStateStream.listen((event) {
      if (event == ProcessingState.completed) {
        stop();
      }
    });

    _player.currentIndexStream.listen((event) async {
      if (event == null) return;

      final currentItem = _getQueueItem(event);
      mediaItem.add(currentItem);

      if (!FinampSettingsHelper.finampSettings.isOffline) {
        await _updatePlaybackInfo(currentItem);
      }
    });

    // PlaybackEvent doesn't include shuffle/loops so we listen for changes here
    _player.shuffleModeEnabledStream.listen(
        (_) => playbackState.add(_transformEvent(_player.playbackEvent)));
    _player.loopModeStream.listen(
        (_) => playbackState.add(_transformEvent(_player.playbackEvent)));
  }

  Future<void> _updatePlaybackInfo(MediaItem currentItem) async {
    final jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();

    if (_previousItem != null) {
      final playbackData = generatePlaybackProgressInfo(
        item: _previousItem,
        includeNowPlayingQueue: true,
        isStopEvent: true,
      );

      if (playbackData != null) {
        await jellyfinApiHelper.stopPlaybackProgress(playbackData);
      }
    }

    final playbackData = generatePlaybackProgressInfo(
      item: currentItem,
      includeNowPlayingQueue: true,
    );

    if (playbackData != null) {
      await jellyfinApiHelper.reportPlaybackStart(playbackData);
    }

    // Set item for next index update
    _previousItem = currentItem;
  }

  Future<MediaItem> _convertToMediaItem(BaseItemDto item, String categoryId) async {
    final tabContentType = TabContentType.fromItemType(item.type!);
    var id = '${tabContentType.name}|';
    if (item.isFolder ?? tabContentType != TabContentType.songs && categoryId == '-1') {
      id += item.id;
    } else {
      id += '$categoryId|${item.id}';
    }

    final playable = tabContentType == TabContentType.albums || tabContentType == TabContentType.playlists || tabContentType == TabContentType.songs;
    return await _mediaItemHelper.generateMediaItem(item, id: id, playable: playable);
  }

  Future<List<MediaItem>> _getMediaItems(String parentMediaId, {bool getAllSongsInView = false}) async {
    var locale = LocaleHelper.locale;
    // if LocaleHelper.locale is null, it means the default system language is used.
    if (locale == null) {
      final splitLocale = Platform.localeName.split('_');
      if (splitLocale.length == 2) {
        // Remove character set from country code
        if (splitLocale.last.contains('.')) {
          locale = Locale(splitLocale.first, splitLocale.last.substring(0, splitLocale.last.indexOf('.')));
        }
        else {
          locale = Locale(splitLocale.first, splitLocale.last);
        }
      } else {
        locale = Locale(splitLocale.first);
      }
    }

    final appLocalizations = await AppLocalizations.delegate.load(locale);

    // Display the root category
    if (parentMediaId == AudioService.browsableRootId) {
      return [
        MediaItem(
            id: '${TabContentType.albums.name}|-1',
            title: appLocalizations.albums,
            playable: false
        ),
        MediaItem(
            id: '${TabContentType.artists.name}|-1',
            title: appLocalizations.artists,
            playable: false
        ),
        MediaItem(
            id: '${TabContentType.playlists.name}|-1',
            title: appLocalizations.playlists,
            playable: false
        ),
        MediaItem(
            id: '${TabContentType.genres.name}|-1',
            title: appLocalizations.genres,
            playable: false
        ),
        MediaItem(
            id: '${TabContentType.songs.name}|-1',
            title: appLocalizations.songs,
            playable: false
        ),
      ];
    }

    final split = parentMediaId.split('|');
    if (split.length < 2) {
      throw FormatException("Invalid parentMediaId format `$parentMediaId`");
    }
    final type = split[0];
    final categoryId = split[1];
    final itemId = split.length == 3 ? split[2] : null;
    final tabContentType = TabContentType.values.firstWhere((e) => e.name == type);

    // TODO: add offline / downloads support
    // if (FinampSettingsHelper.finampSettings.isOffline) {
    //
    // }

    final sortBy = tabContentType == TabContentType.songs ? "Album,SortName" : tabContentType == TabContentType.artists ? "ProductionYear,PremiereDate" : "SortName";

    // We only need the id, so we don't have to use `_jellyfinApiHelper.getItemById`
    // Uses the current view as fallback to ensure we get the correct items.
    // If category id is defined, use that. Otherwise, if an item id is defined
    final parentItem = categoryId != '-1'
        ? BaseItemDto(id: categoryId, type: tabContentType.itemType())
        : (itemId != null && (tabContentType != TabContentType.songs || !getAllSongsInView) // getAllSongsInView is used here for finding the index of the song in `playFromMediaId` when playing from the songs category.
          ? BaseItemDto(id: itemId, type: tabContentType.itemType())
          : _finampUserHelper.currentUser?.currentView);

    // Select the item type that each category holds
    final includeItemTypes = categoryId != '-1' // If categoryId is -1, we are browsing a root library. e.g. Browsing the list of all albums or artists.
        ? (tabContentType == TabContentType.albums ? TabContentType.songs.itemType() // List an album's songs.
          : tabContentType == TabContentType.artists ? TabContentType.albums.itemType() // List an artist's albums.
          : tabContentType == TabContentType.playlists ? TabContentType.songs.itemType() // List a playlist's songs.
          : tabContentType == TabContentType.genres ? TabContentType.albums.itemType() // List a genre's albums.
          : tabContentType == TabContentType.songs ? TabContentType.songs.itemType()
          : throw FormatException("Unsupported TabContentType `$tabContentType`"))
        : tabContentType.itemType(); // Display the root library.

    final items = await _jellyfinApiHelper.getItems(parentItem: parentItem, sortBy: sortBy, includeItemTypes: includeItemTypes, isGenres: tabContentType == TabContentType.genres);
    List<MediaItem> mediaItems = items != null ? [for (final item in items) await _convertToMediaItem(item, categoryId)] : [];
    return mediaItems;
  }

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId, [Map<String, dynamic>? options]) async {
    if (!parentMediaId.contains('|') && parentMediaId != AudioService.browsableRootId) {
      return super.getChildren(parentMediaId);
    }
    return await _getMediaItems(parentMediaId);
  }

  // https://github.com/ryanheise/audio_service/blob/audio_service-v0.18.10/audio_service/example/lib/example_multiple_handlers.dart#L367
  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= queue.value.length) return;
    // This jumps to the beginning of the queue item at newIndex.
    _player.seek(Duration.zero, index: index);
  }

  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
    final split = mediaId.split('|');
    if (split.length < 2) {
      return super.prepareFromMediaId(mediaId, extras);
    }
    final type = split[0];
    final categoryId = split[1];
    final itemId = split.length == 3 ? split[2] : null;

    // Get all songs in current category (either a single album, or all the songs in view)
    final categoryMediaItems = await _getMediaItems(mediaId, getAllSongsInView: true);

    // If we're playing an individual song, find the index of it in the category and skip to it.
    var index = 0;
    if (itemId != null) {
      final mediaItem = await _mediaItemHelper.generateMediaItem(await _jellyfinApiHelper.getItemById(itemId), id: '$type|$categoryId|$itemId');
      index = categoryMediaItems.indexOf(mediaItem);
      setNextInitialIndex(index);
    }

    // TODO: add shuffling?

    await updateQueue(categoryMediaItems);

    final currentItem = _getQueueItem(index);
    mediaItem.add(currentItem);
    _updatePlaybackInfo(currentItem);
    await play();
  }

  @override
  Future<void> play() {
    // If a sleep timer has been set and the timer went off
    //  causing play to pause, if the user starts to play
    //  audio again, and the sleep timer hasn't been explicitly
    //  turned off, then reset the sleep timer.
    // This is useful if the sleep timer pauses play too early
    //  and the user wants to continue listening
    if (_sleepTimerIsSet && _sleepTimer.value == null) {
      // restart the sleep timer for another period
      setSleepTimer(_sleepTimerDuration);
    }

    return _player.play();
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    try {
      _audioServiceBackgroundTaskLogger.info("Stopping audio service");

      _isStopping = true;

      // Clear the previous item.
      _previousItem = null;

      // Tell Jellyfin we're no longer playing audio if we're online
      if (!FinampSettingsHelper.finampSettings.isOffline) {
        final playbackInfo =
            generatePlaybackProgressInfo(includeNowPlayingQueue: false);
        if (playbackInfo != null) {
          await _jellyfinApiHelper.stopPlaybackProgress(playbackInfo);
        }
      }

      // Stop playing audio.
      await _player.stop();

      // Seek to the start of the first item in the queue
      await _player.seek(Duration.zero, index: 0);

      _sleepTimerIsSet = false;
      _sleepTimerDuration = Duration.zero;

      _sleepTimer.value?.cancel();
      _sleepTimer.value = null;

      await super.stop();

      // await _player.dispose();
      // await _eventSubscription?.cancel();
      // // It is important to wait for this state to be broadcast before we shut
      // // down the task. If we don't, the background task will be destroyed before
      // // the message gets sent to the UI.
      // await _broadcastState();
      // // Shut down this background task
      // await super.stop();

      _isStopping = false;
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
    try {
      await _queueAudioSource.add(await _mediaItemToAudioSource(mediaItem));
      queue.add(_queueFromSource());
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  @override
  Future<void> updateQueue(List<MediaItem> newQueue) async {
    try {
      // Convert the MediaItems to AudioSources
      List<AudioSource> audioSources = [];
      for (final mediaItem in newQueue) {
        audioSources.add(await _mediaItemToAudioSource(mediaItem));
      }

      // Create a new ConcatenatingAudioSource with the new queue.
      _queueAudioSource = ConcatenatingAudioSource(
        children: audioSources,
      );

      try {
        await _player.setAudioSource(
          _queueAudioSource,
          initialIndex: nextInitialIndex,
        );
      } on PlayerException catch (e) {
        _audioServiceBackgroundTaskLogger
            .severe("Player error code ${e.code}: ${e.message}");
      } on PlayerInterruptedException catch (e) {
        _audioServiceBackgroundTaskLogger
            .warning("Player interrupted: ${e.message}");
      } catch (e) {
        _audioServiceBackgroundTaskLogger
            .severe("Player error ${e.toString()}");
      }
      queue.add(_queueFromSource());

      // Sets the media item for the new queue. This will be whatever is
      // currently playing from the new queue (for example, the first song in
      // an album). If the player is shuffling, set the index to the player's
      // current index. Otherwise, set it to nextInitialIndex. nextInitialIndex
      // is much more stable than the current index as we know the value is set
      // when running this function.
      if (_player.shuffleModeEnabled) {
        if (_player.currentIndex == null) {
          _audioServiceBackgroundTaskLogger.severe(
              "_player.currentIndex is null during onUpdateQueue, not setting new media item");
        } else {
          mediaItem.add(_getQueueItem(_player.currentIndex!));
        }
      } else {
        if (nextInitialIndex == null) {
          _audioServiceBackgroundTaskLogger.severe(
              "nextInitialIndex is null during onUpdateQueue, not setting new media item");
        } else {
          mediaItem.add(_getQueueItem(nextInitialIndex!));
        }
      }

      shuffleNextQueue = false;
      nextInitialIndex = null;
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  @override
  Future<void> skipToPrevious() async {
    try {
      if (!_player.hasPrevious || _player.position.inSeconds >= 5) {
        await _player.seek(Duration.zero, index: _player.currentIndex);
      } else {
        await _player.seek(Duration.zero, index: _player.previousIndex);
      }
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  @override
  Future<void> skipToNext() async {
    try {
      await _player.seekToNext();
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  Future<void> skipToIndex(int index) async {
    try {
      await _player.seek(Duration.zero, index: index);
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  @override
  Future<void> seek(Duration position) async {
    try {
      await _player.seek(position);
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    try {
      switch (shuffleMode) {
        case AudioServiceShuffleMode.all:
          await _player.setShuffleModeEnabled(true);
          shuffleNextQueue = true;
          break;
        case AudioServiceShuffleMode.none:
          await _player.setShuffleModeEnabled(false);
          shuffleNextQueue = false;
          break;
        default:
          return Future.error(
              "Unsupported AudioServiceRepeatMode! Recieved ${shuffleMode.toString()}, requires all or none.");
      }
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    try {
      switch (repeatMode) {
        case AudioServiceRepeatMode.all:
          await _player.setLoopMode(LoopMode.all);
          break;
        case AudioServiceRepeatMode.none:
          await _player.setLoopMode(LoopMode.off);
          break;
        case AudioServiceRepeatMode.one:
          await _player.setLoopMode(LoopMode.one);
          break;
        default:
          return Future.error(
              "Unsupported AudioServiceRepeatMode! Recieved ${repeatMode.toString()}, requires all, none, or one.");
      }
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  @override
  Future<void> removeQueueItemAt(int index) async {
    try {
      await _queueAudioSource.removeAt(index);
      queue.add(_queueFromSource());
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  /// Generates PlaybackProgressInfo from current player info. Returns null if
  /// _queue is empty. If an item is not supplied, the current queue index will
  /// be used.
  PlaybackProgressInfo? generatePlaybackProgressInfo({
    MediaItem? item,
    required bool includeNowPlayingQueue,
    bool isStopEvent = false,
  }) {
    if (_queueAudioSource.length == 0 && item == null) {
      // This function relies on _queue having items, so we return null if it's
      // empty to avoid more errors.
      return null;
    }

    try {
      return PlaybackProgressInfo(
        itemId: item?.extras?["itemJson"]["Id"] ??
            _getQueueItem(_player.currentIndex ?? 0).extras!["itemJson"]["Id"],
        isPaused: !_player.playing,
        isMuted: _player.volume == 0,
        positionTicks: isStopEvent
            ? (item?.duration?.inMicroseconds ?? 0) * 10
            : _player.position.inMicroseconds * 10,
        repeatMode: _jellyfinRepeatMode(_player.loopMode),
        playMethod: item?.extras!["shouldTranscode"] ??
                _getQueueItem(_player.currentIndex ?? 0)
                    .extras!["shouldTranscode"]
            ? "Transcode"
            : "DirectPlay",
        // We don't send the queue since it seems useless and it can cause
        // issues with large queues.
        // https://github.com/jmshrv/finamp/issues/387

        // nowPlayingQueue: includeNowPlayingQueue
        //     ? _queueFromSource()
        //         .map(
        //           (e) => QueueItem(
        //               id: e.extras!["itemJson"]["Id"], playlistItemId: e.id),
        //         )
        //         .toList()
        //     : null,
      );
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      rethrow;
    }
  }

  void setNextInitialIndex(int index) {
    nextInitialIndex = index;
  }

  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    // When we're moving an item forwards, we need to reduce newIndex by 1
    // to account for the current item being removed before re-insertion.
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    await _queueAudioSource.move(oldIndex, newIndex);
    queue.add(_queueFromSource());
    _audioServiceBackgroundTaskLogger.log(Level.INFO, "Published queue");
  }

  /// Sets the sleep timer with the given [duration].
  Timer setSleepTimer(Duration duration) {
    _sleepTimerIsSet = true;
    _sleepTimerDuration = duration;

    _sleepTimer.value = Timer(duration, () async {
      _sleepTimer.value = null;
      return await pause();
    });
    return _sleepTimer.value!;
  }

  /// Cancels the sleep timer and clears it.
  void clearSleepTimer() {
    _sleepTimerIsSet = false;
    _sleepTimerDuration = Duration.zero;

    _sleepTimer.value?.cancel();
    _sleepTimer.value = null;
  }

  /// Transform a just_audio event into an audio_service state.
  ///
  /// This method is used from the constructor. Every event received from the
  /// just_audio player will be transformed into an audio_service state so that
  /// it can be broadcast to audio_service clients.
  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 3],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: event.currentIndex,
      shuffleMode: _player.shuffleModeEnabled
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
      repeatMode: _audioServiceRepeatMode(_player.loopMode),
    );
  }

  Future<void> _updatePlaybackProgress() async {
    try {
      JellyfinApiHelper jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();

      final playbackInfo =
          generatePlaybackProgressInfo(includeNowPlayingQueue: false);
      if (playbackInfo != null) {
        await jellyfinApiHelper.updatePlaybackProgress(playbackInfo);
      }
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  MediaItem _getQueueItem(int index) {
    return _queueAudioSource.sequence[index].tag as MediaItem;
  }

  List<MediaItem> _queueFromSource() {
    return _queueAudioSource.sequence.map((e) => e.tag as MediaItem).toList();
  }

  /// Syncs the list of MediaItems (_queue) with the internal queue of the player.
  /// Called by onAddQueueItem and onUpdateQueue.
  Future<AudioSource> _mediaItemToAudioSource(MediaItem mediaItem) async {
    if (mediaItem.extras!["downloadedSongJson"] == null) {
      // If DownloadedSong wasn't passed, we assume that the item is not
      // downloaded.

      // If offline, we throw an error so that we don't accidentally stream from
      // the internet. See the big comment in _songUri() to see why this was
      // passed in extras.
      if (mediaItem.extras!["isOffline"]) {
        return Future.error(
            "Offline mode enabled but downloaded song not found.");
      } else {
        if (mediaItem.extras!["shouldTranscode"] == true) {
          return HlsAudioSource(await _songUri(mediaItem), tag: mediaItem);
        } else {
          return AudioSource.uri(await _songUri(mediaItem), tag: mediaItem);
        }
      }
    } else {
      // We have to deserialise this because Dart is stupid and can't handle
      // sending classes through isolates.
      final downloadedSong =
          DownloadedSong.fromJson(mediaItem.extras!["downloadedSongJson"]);

      // Path verification and stuff is done in AudioServiceHelper, so this path
      // should be valid.
      final downloadUri = Uri.file(downloadedSong.file.path);
      return AudioSource.uri(downloadUri, tag: mediaItem);
    }
  }

  Future<Uri> _songUri(MediaItem mediaItem) async {
    // We need the platform to be Android or iOS to get device info
    assert(Platform.isAndroid || Platform.isIOS,
        "_songUri() only supports Android and iOS");

    // When creating the MediaItem (usually in AudioServiceHelper), we specify
    // whether or not to transcode. We used to pull from FinampSettings here,
    // but since audio_service runs in an isolate (or at least, it does until
    // 0.18), the value would be wrong if changed while a song was playing since
    // Hive is bad at multi-isolate stuff.

    final androidId =
        Platform.isAndroid ? await const AndroidId().getId() : null;
    final iosDeviceInfo =
        Platform.isIOS ? await DeviceInfoPlugin().iosInfo : null;

    final parsedBaseUrl = Uri.parse(_finampUserHelper.currentUser!.baseUrl);

    List<String> builtPath = List.from(parsedBaseUrl.pathSegments);

    Map<String, String> queryParameters =
        Map.from(parsedBaseUrl.queryParameters);

    // We include the user token as a query parameter because just_audio used to
    // have issues with headers in HLS, and this solution still works fine
    queryParameters["ApiKey"] = _finampUserHelper.currentUser!.accessToken;

    if (mediaItem.extras!["shouldTranscode"]) {
      builtPath.addAll([
        "Audio",
        mediaItem.extras!["itemJson"]["Id"],
        "main.m3u8",
      ]);

      queryParameters.addAll({
        "audioCodec": "aac",
        // Ideally we'd use 48kHz when the source is, realistically it doesn't
        // matter too much
        "audioSampleRate": "44100",
        "maxAudioBitDepth": "16",
        "audioBitRate":
            FinampSettingsHelper.finampSettings.transcodeBitrate.toString(),
      });
    } else {
      builtPath.addAll([
        "Items",
        mediaItem.extras!["itemJson"]["Id"],
        "File",
      ]);
    }

    return Uri(
      host: parsedBaseUrl.host,
      port: parsedBaseUrl.port,
      scheme: parsedBaseUrl.scheme,
      userInfo: parsedBaseUrl.userInfo,
      pathSegments: builtPath,
      queryParameters: queryParameters,
    );
  }
}

String _jellyfinRepeatMode(LoopMode loopMode) {
  switch (loopMode) {
    case LoopMode.all:
      return "RepeatAll";
    case LoopMode.one:
      return "RepeatOne";
    case LoopMode.off:
      return "RepeatNone";
  }
}

AudioServiceRepeatMode _audioServiceRepeatMode(LoopMode loopMode) {
  switch (loopMode) {
    case LoopMode.off:
      return AudioServiceRepeatMode.none;
    case LoopMode.one:
      return AudioServiceRepeatMode.one;
    case LoopMode.all:
      return AudioServiceRepeatMode.all;
  }
}
