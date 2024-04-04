import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:auto_direction/auto_direction.dart';
import 'package:dart_twitter_api/twitter_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:squawker/client/client.dart';
import 'package:squawker/constants.dart';
import 'package:squawker/generated/l10n.dart';
import 'package:squawker/import_data_model.dart';
import 'package:squawker/profile/profile.dart';
import 'package:squawker/saved/saved_tweet_model.dart';
import 'package:squawker/search/search.dart';
import 'package:squawker/status.dart';
import 'package:squawker/tweet/_card.dart';
import 'package:squawker/tweet/_context_menu.dart';
import 'package:squawker/tweet/_entities.dart';
import 'package:squawker/tweet/_media.dart';
import 'package:squawker/ui/dates.dart';
import 'package:squawker/ui/errors.dart';
import 'package:squawker/user.dart';
import 'package:squawker/utils/data_service.dart';
import 'package:squawker/utils/iterables.dart';
import 'package:squawker/utils/misc.dart';
import 'package:squawker/utils/translation.dart';
import 'package:squawker/utils/urls.dart';
import 'package:html_unescape/html_unescape.dart';
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';
import 'package:pref/pref.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:visibility_detector/visibility_detector.dart';

class TweetTile extends StatefulWidget {
  final String? conversationId;
  final bool clickable;
  final String? currentUsername;
  final TweetWithCard tweet;
  final bool isPinned;
  final bool isThread;
  final int? tweetIdx;
  final VisiblePositionState? visiblePositionState;

  const TweetTile(
      {Key? key,
      this.conversationId,
      required this.clickable,
      this.currentUsername,
      required this.tweet,
      this.isPinned = false,
      this.isThread = false,
      this.tweetIdx,
      this.visiblePositionState})
      : super(key: key);

  @override
  TweetTileState createState() => TweetTileState();
}

class TweetTileState extends State<TweetTile> with SingleTickerProviderStateMixin {
  static final log = Logger('TweetTile');

  late final bool clickable;
  late final String? currentUsername;
  late final TweetWithCard tweet;
  late final bool isPinned;
  late final bool isThread;

  TranslationStatus _translationStatus = TranslationStatus.original;

  List<TweetTextPart> _originalParts = [];
  List<TweetTextPart> _displayParts = [];
  List<TweetTextPart> _translatedParts = [];

  List<String> _extraContextMenuItems = [];

  final GlobalKey _globalKey = GlobalKey();

  static String? _convertRunesToText(Iterable<int> runes, int start, [int? end]) {
    var string = runes.getRange(start, end).map((e) => String.fromCharCode(e)).join('');
    if (string.isEmpty) {
      return null;
    }

    return HtmlUnescape().convert(string);
  }

  static List<TweetEntity> _populateEntities(
      {required List<TweetEntity> entities, List<dynamic>? source, required Function getNewEntity}) {
    source = source ?? [];

    for (dynamic newEntity in source) {
      entities.add(getNewEntity(newEntity));
    }

    return entities;
  }

  static List<TweetEntity> _getEntities(BuildContext context, TweetWithCard tweet) {
    List<TweetEntity> entities = [];

    entities = _populateEntities(
        entities: entities,
        source: tweet.entities?.hashtags,
        getNewEntity: (Hashtag hashtag) {
          return TweetHashtag(
              hashtag,
              () => Navigator.pushNamed(context, routeSearch,
                  arguments: SearchArguments(1, focusInputOnOpen: false, query: '#${hashtag.text}')));
        });

    entities = _populateEntities(
        entities: entities,
        source: tweet.entities?.userMentions,
        getNewEntity: (UserMention mention) {
          return TweetUserMention(mention, () {
            Navigator.pushNamed(context, routeProfile,
                arguments: ProfileScreenArguments(mention.idStr, mention.screenName));
          });
        });

    entities = _populateEntities(
        entities: entities,
        source: tweet.entities?.urls,
        getNewEntity: (Url url) {
          return TweetUrl(url, () async {
            String? uri = url.expandedUrl;
            if (uri == null ||
                (uri.length > 27 && uri.toLowerCase().substring(0, 27) == 'https://x.com/i/web/status/') ||
                (uri.length > 33 && uri.toLowerCase().substring(0, 33) == 'https://twitter.com/i/web/status/')) {
              return;
            }

            await openUri(uri);
          });
        });

    entities.sort((a, b) => a.getEntityStart().compareTo(b.getEntityStart()));

    return entities;
  }

  Future<void> onClickTranslate() async {
    // If we've already translated this text before, use those results instead of translating again
    if (_translatedParts.isNotEmpty) {
      return setState(() {
        _displayParts = _translatedParts;
        _translationStatus = TranslationStatus.translated;
      });
    }

    setState(() {
      _translationStatus = TranslationStatus.translating;
    });

    try {
      var systemLocale = getShortSystemLocale();

      var isLanguageSupported = await isLanguageSupportedForTranslation(systemLocale);
      if (!isLanguageSupported) {
        return showTranslationError('Your system language ($systemLocale) is not supported for translation');
      }
    } catch (e) {
      log.severe('Unable to list the supported languages');

      return showTranslationError(
          'Failed to get the list of supported languages. Please check your connection, or try again later!');
    }

    var originalText = _originalParts.map((e) => e.toString()).toList();

    var res = await TranslationAPI.translate(context, tweet.idStr!, originalText, tweet.lang ?? "");
    if (res.success) {
      var translatedParts = convertTextPartsToTweetEntities(List.from(res.body['translatedText']));

      // We cache the translated parts in a property in case the user swaps back and forth
      return setState(() {
        _displayParts = translatedParts;
        _translatedParts = translatedParts;
        _translationStatus = TranslationStatus.translated;
      });
    } else {
      return showTranslationError(res.errorMessage ?? 'An unknown error occurred while translating');
    }
  }

  void showTranslationError(String message) {
    setState(() {
      _translationStatus = TranslationStatus.translationFailed;
    });

    showSnackBar(context, icon: '💥', message: message);
  }

  Future<void> onClickShowOriginal() async {
    setState(() {
      _displayParts = _originalParts;
      _translationStatus = TranslationStatus.original;
    });
  }

  void onClickOpenTweet(TweetWithCard tweet) {
    Navigator.pushNamed(context, routeStatus,
        arguments: StatusScreenArguments(id: tweet.idStr!, username: tweet.user!.screenName!));
  }

  List<TweetTextPart> convertTextPartsToTweetEntities(List<String> parts) {
    List<TweetTextPart> translatedParts = [];

    for (var i = 0; i < parts.length; i++) {
      var thing = _originalParts[i];
      if (thing.plainText != null) {
        translatedParts.add(TweetTextPart(null, parts[i]));
      } else {
        translatedParts.add(TweetTextPart(thing.entity, null));
      }
    }

    return translatedParts;
  }

  void _getExtraContextMenuItems() async {
    _extraContextMenuItems = await getSupportedTextActivityList();
  }

  @override
  void initState() {
    super.initState();

    _getExtraContextMenuItems();

    clickable = widget.clickable;
    currentUsername = widget.currentUsername;
    tweet = widget.tweet;
    isPinned = widget.isPinned;
    isThread = widget.isThread;

    // Get the text to display from the actual tweet, i.e. the retweet if there is one, otherwise we end up with "RT @" crap in our text
    var actualTweet = tweet.retweetedStatusWithCard ?? tweet;

    // This is some super long text that I think only Twitter Blue users can write
    var noteText = tweet.noteText;

    // Generate all the tweet entities (mentions, hashtags, etc.) from the tweet text
    Runes tweetText = Runes(noteText ?? actualTweet.fullText ?? actualTweet.text!);

    // If we're not given a text display range, we just display the entire text
    List<int> displayTextRange;
    if (noteText == null) {
      displayTextRange = actualTweet.displayTextRange ?? [0, tweetText.length];
    } else {
      displayTextRange = [0, noteText.length];
    }

    Iterable<int> runes = tweetText.getRange(displayTextRange[0], displayTextRange[1]);

    List<TweetEntity> entities = _getEntities(context, actualTweet);
    List<TweetTextPart> things = [];

    int index = 0;

    for (var part in entities) {
      // Generate new indices for the entity start and end, by subtracting the displayTextRange's start index, as we ignore text up until that point
      int start = part.getEntityStart() - displayTextRange[0];
      int end = part.getEntityEnd() - displayTextRange[0];

      // Only add entities that are after the displayTextRange's start index
      if (start < 0) {
        continue;
      }

      // Add any text between the last entity's end and the start of this one
      var textPart = _convertRunesToText(runes, index, start);
      if (textPart != null) {
        things.add(TweetTextPart(null, textPart));
      }

      // Then add the actual entity
      bool addPartContent = false;
      if (part is TweetUrl) {
        TweetUrl urlEnt = part;
        if (urlEnt.url.expandedUrl == null || !_isTwitterUrl(urlEnt.url.expandedUrl!)) {
          addPartContent = true;
        }
      }
      else {
        addPartContent = true;
      }
      if (addPartContent) {
        things.add(TweetTextPart(part.getContent(), null));
      }

      // Then set our index in the tweet text as the end of our entity
      index = end;
    }

    var textPart = _convertRunesToText(runes, index);
    if (textPart != null) {
      things.add(TweetTextPart(null, textPart));
    }

    setState(() {
      _displayParts = things;
      _originalParts = things;
    });
  }

  static const List<String> _twitterUrls = [
    'x.com',
    'twitter.com',
    'pic.twitter.com',
    'twimg.com',
    'abs.twimg.com',
    'pbs.twimg.com',
    'video.twimg.com'
  ];

  bool _isTwitterUrl(String url) {
    return _twitterUrls.firstWhereOrNull((elm) => url.startsWith('https://$elm/')) != null;
  }

  _createFooterIconButton(IconData icon, [Color? color, double? fill, Function()? onPressed]) {
    return IconButton(
      icon: Icon(
        icon,
        fill: fill,
      ),
      color: color ?? Theme.of(context).colorScheme.primary,
      iconSize: 20,
      onPressed: onPressed,
    );
  }

  _createFooterTextButton(IconData icon, String label, [Color? color, Function()? onPressed]) {
    return TextButton.icon(
      icon: Icon(icon, size: 20, color: color),
      onPressed: onPressed,
      label: Text(label, style: TextStyle(color: color, fontSize: 14)),
    );
  }

  Widget _contextMenuBuilder(BuildContext context, EditableTextState editableTextState) {
    return customContextMenuBuilder(context, editableTextState, _extraContextMenuItems, processTextActivity);
  }

  Future<Uint8List?> captureWidget() async {
    if (_globalKey.currentContext == null) {
      return null;
    }
    final RenderRepaintBoundary boundary = _globalKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final ui.Image image = await boundary.toImage();
    final ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) {
      return null;
    }
    final Uint8List pngBytes = byteData.buffer.asUint8List();

    return pngBytes;
  }

  @override
  Widget build(BuildContext context) {
    final prefs = PrefService.of(context, listen: false);

    double optionTweetFontSizeValue =
        prefs.get<int>(optionTweetFontSize)?.toDouble() ?? DefaultTextStyle.of(context).style.fontSize!;

    var shareBaseUrlOption = prefs.get(optionShareBaseUrl);
    var shareBaseUrl =
        shareBaseUrlOption != null && shareBaseUrlOption.isNotEmpty ? shareBaseUrlOption : 'https://x.com';

    TweetWithCard tweet = this.tweet.retweetedStatusWithCard == null ? this.tweet : this.tweet.retweetedStatusWithCard!;

    // If the user is on a profile, all the shown tweets are from that profile, so it makes no sense to hide it
    final isTweetOnSameProfile = currentUsername != null && currentUsername == tweet.user!.screenName;
    final hideAuthorInformation = !isTweetOnSameProfile && prefs.get(optionNonConfirmationBiasMode);

    var numberFormat = NumberFormat.compact();
    var theme = Theme.of(context);

    if (tweet.isTombstone ?? false) {
      return VisibilityDetector(
          key: UniqueKey(),
          onVisibilityChanged: (visibilityInfo) {
            if (visibilityInfo.visibleFraction > 0) {
              if (widget.visiblePositionState != null) {
                widget.visiblePositionState!.positionChanged(widget.conversationId, this.tweet.idStr, widget.tweetIdx);
              }
            }
          },
          child: SizedBox(
            width: double.infinity,
            child: Card(
              child: Container(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(tweet.text!,
                      style: TextStyle(fontStyle: FontStyle.italic, fontSize: optionTweetFontSizeValue),
                      contextMenuBuilder: _contextMenuBuilder)),
            ),
          ));
    }

    Widget media = Container();
    if (tweet.extendedEntities?.media != null && tweet.extendedEntities!.media!.isNotEmpty) {
      media = TweetMedia(
        sensitive: tweet.possiblySensitive,
        media: tweet.extendedEntities!.media!,
        username: tweet.user!.screenName!,
      );
    }

    Widget retweetBanner = Container();
    Widget retweetSidebar = Container();
    if (this.tweet.retweetedStatusWithCard != null) {
      retweetBanner = _TweetTileLeading(
        icon: Symbols.repeat,
        onTap: () => Navigator.pushNamed(context, routeProfile,
            arguments: ProfileScreenArguments.fromScreenName(this.tweet.user!.screenName!)),
        children: [
          TextSpan(
              text: L10n.of(context)
                  .this_tweet_user_name_retweeted(this.tweet.user!.name!, createRelativeDate(this.tweet.createdAt!)),
              style: theme.textTheme.bodySmall)
        ],
      );

      retweetSidebar = Container(color: theme.secondaryHeaderColor, width: 4);
    }

    Widget replyToTile = Container();
    var replyTo = tweet.inReplyToScreenName;
    if (replyTo != null) {
      replyToTile = _TweetTileLeading(
        onTap: () {
          var replyToId = tweet.inReplyToStatusIdStr;
          if (replyToId == null) {
            ScaffoldMessenger.of(context).clearSnackBars();
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(
                L10n.of(context).sorry_the_replied_tweet_could_not_be_found,
              ),
            ));
          } else {
            Navigator.pushNamed(context, routeStatus,
                arguments: StatusScreenArguments(id: replyToId, username: replyTo));
          }
        },
        icon: Symbols.reply_rounded,
        children: [
          TextSpan(text: '${L10n.of(context).replying_to} ', style: theme.textTheme.bodySmall),
          TextSpan(text: '@$replyTo', style: theme.textTheme.bodySmall!.copyWith(fontWeight: FontWeight.bold)),
        ],
      );
    }

    var tweetText = tweet.fullText ?? tweet.text;
    if (tweetText == null) {
      return VisibilityDetector(
          key: UniqueKey(),
          onVisibilityChanged: (visibilityInfo) {
            if (visibilityInfo.visibleFraction > 0) {
              if (widget.visiblePositionState != null) {
                widget.visiblePositionState!.positionChanged(widget.conversationId, this.tweet.idStr, widget.tweetIdx);
              }
            }
          },
          child: Text(L10n.of(context).the_tweet_did_not_contain_any_text_this_is_unexpected,
              style: TextStyle(fontSize: optionTweetFontSizeValue)));
    }

    var quotedTweet = Container();

    if (tweet.isQuoteStatus ?? false) {
      if (tweet.quotedStatusWithCard != null) {
        quotedTweet = Container(
          decoration:
              BoxDecoration(border: Border.all(color: theme.primaryColor), borderRadius: BorderRadius.circular(8)),
          margin: const EdgeInsets.all(8),
          child: TweetTile(
            clickable: true,
            tweet: tweet.quotedStatusWithCard!,
            currentUsername: currentUsername,
          ),
        );
      }
    }

    // Only create the tweet content if the tweet contains text
    Widget content = Container();

    if (tweet.displayTextRange![1] != 0) {
      content = Container(
        // Fill the width so both RTL and LTR text are displayed correctly
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        child: AutoDirection(
            text: tweetText,
            child: SelectableText.rich(
              TextSpan(children: [
                ..._displayParts.map((e) {
                  if (e.plainText != null) {
                    return TextSpan(text: e.plainText, style: TextStyle(fontSize: optionTweetFontSizeValue));
                  } else {
                    return e.entity!;
                  }
                })
              ]),
              onTap: () => onClickOpenTweet(tweet),
              contextMenuBuilder: _contextMenuBuilder,
            )),
      );
    }

    Widget translateButton;
    switch (_translationStatus) {
      case TranslationStatus.original:
        translateButton =
            _createFooterIconButton(Symbols.translate_rounded, Colors.blue, null, () async => onClickTranslate());
        break;
      case TranslationStatus.translating:
        translateButton = const Padding(
          padding: EdgeInsets.symmetric(horizontal: 24),
          child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator()),
        );
        break;
      case TranslationStatus.translationFailed:
        translateButton =
            _createFooterIconButton(Symbols.translate_rounded, Colors.red, null, () async => onClickTranslate());
        break;
      case TranslationStatus.translated:
        translateButton =
            _createFooterIconButton(Symbols.translate_rounded, Colors.green, null, () async => onClickShowOriginal());
        break;
    }

    DateTime? createdAt;
    if (tweet.createdAt != null) {
      createdAt = tweet.createdAt;
    }

    return VisibilityDetector(
        key: UniqueKey(),
        onVisibilityChanged: (visibilityInfo) {
          if (visibilityInfo.visibleFraction > 0) {
            if (widget.visiblePositionState != null) {
              widget.visiblePositionState!.positionChanged(widget.conversationId, this.tweet.idStr, widget.tweetIdx);
            }
          }
        },
        child: Consumer<ImportDataModel>(
            builder: (context, model, child) => RepaintBoundary(
                key: _globalKey,
                child: Card(
                  color: prefs.get(optionThemeMode) == 'dark' && prefs.get(optionThemeTrueBlack) == true
                      ? Colors.black
                      : null,
                  child: Row(
                    children: [
                      retweetSidebar,
                      Expanded(
                          child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          retweetBanner,
                          replyToTile,
                          if (isPinned)
                            _TweetTileLeading(icon: Symbols.push_pin_rounded, children: [
                              TextSpan(
                                text: L10n.of(context).pinned_tweet,
                                style: theme.textTheme.bodySmall,
                              )
                            ]),
                          if (isThread)
                            _TweetTileLeading(icon: Symbols.forum_rounded, children: [
                              TextSpan(
                                text: L10n.of(context).thread,
                                style: theme.textTheme.bodySmall,
                              )
                            ]),
                          ListTile(
                            onTap: () {
                              // If the tweet is by the currently-viewed profile, don't allow clicks as it doesn't make sense
                              if (currentUsername != null && tweet.user!.screenName!.endsWith(currentUsername!)) {
                                return;
                              }

                              Navigator.pushNamed(context, routeProfile,
                                  arguments: ProfileScreenArguments(tweet.user!.idStr, tweet.user!.screenName));
                            },
                            title: Row(
                              children: [
                                // Username
                                if (!hideAuthorInformation)
                                  Flexible(
                                    child: Row(
                                      children: [
                                        Flexible(
                                            child: Text(tweet.user!.name!,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(fontWeight: FontWeight.w500))),
                                        if (tweet.user!.verified ?? false) const SizedBox(width: 4),
                                        if (tweet.user!.verified ?? false)
                                          Icon(Symbols.verified, size: 18, color: Theme.of(context).primaryColor)
                                      ],
                                    ),
                                  ),
                                InkWell(
                                  child: const Icon(Symbols.more_horiz),
                                  onTap: () async {
                                    createSheetButton(title, icon, onTap) => ListTile(
                                          onTap: onTap,
                                          leading: Icon(icon),
                                          title: Text(title),
                                        );

                                    showModalBottomSheet(
                                        context: context,
                                        builder: (context) {
                                          return SafeArea(
                                              child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              createSheetButton(L10n.of(context).share_tweet_content, Symbols.share,
                                                  () async {
                                                Share.share(tweetText);
                                                Navigator.pop(context);
                                              }),
                                              createSheetButton(L10n.of(context).share_tweet_link, Symbols.share,
                                                  () async {
                                                Share.share(
                                                    '$shareBaseUrl/${tweet.user!.screenName}/status/${tweet.idStr}');
                                                Navigator.pop(context);
                                              }),
                                              createSheetButton(
                                                  L10n.of(context).share_tweet_content_and_link, Symbols.share,
                                                  () async {
                                                Share.share(
                                                    '$tweetText\n\n$shareBaseUrl/${tweet.user!.screenName}/status/${tweet.idStr}');
                                                Navigator.pop(context);
                                              }),
                                              createSheetButton(L10n.of(context).share_tweet_as_image, Symbols.share,
                                                  () async {
                                                Uint8List? imgBytes = await captureWidget();
                                                if (imgBytes != null) {
                                                  Share.shareXFiles([XFile.fromData(imgBytes, mimeType: 'image/png')]);
                                                }
                                                Navigator.pop(context);
                                              }),
                                              const Padding(
                                                padding: EdgeInsets.symmetric(horizontal: 16),
                                                child: Divider(
                                                  thickness: 1.0,
                                                ),
                                              ),
                                              createSheetButton(L10n.of(context).cancel, Symbols.close_rounded, () {
                                                Navigator.pop(context);
                                              })
                                            ],
                                          ));
                                        });
                                  },
                                )
                              ],
                            ),
                            subtitle: Row(
                              mainAxisAlignment:
                                  hideAuthorInformation ? MainAxisAlignment.end : MainAxisAlignment.spaceBetween,
                              children: [
                                // Twitter name
                                if (!hideAuthorInformation) ...[
                                  Flexible(child: Text('@${tweet.user!.screenName!}', overflow: TextOverflow.ellipsis)),
                                  const SizedBox(width: 4),
                                ],
                                if (createdAt != null)
                                  DefaultTextStyle(
                                      style: theme.textTheme.bodySmall!, child: Timestamp(timestamp: createdAt))
                              ],
                            ),
                            // Profile picture
                            leading: hideAuthorInformation
                                ? const Icon(Symbols.account_circle_rounded, size: 48)
                                : ClipRRect(
                                    borderRadius: BorderRadius.circular(64),
                                    child: UserAvatar(uri: tweet.user!.profileImageUrlHttps),
                                  ),
                          ),
                          content,
                          media,
                          quotedTweet,
                          TweetCard(tweet: tweet, card: tweet.card),
                          Container(
                            alignment: Alignment.center,
                            margin: const EdgeInsets.symmetric(horizontal: 8),
                            child: Scrollbar(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: [
                                    _createFooterTextButton(
                                        Symbols.comment,
                                        tweet.replyCount != null ? numberFormat.format(tweet.replyCount) : '',
                                        null,
                                        () => onClickOpenTweet(tweet)),
                                    if (tweet.retweetCount != null || tweet.quoteCount != null)
                                      _createFooterTextButton(Symbols.repeat,
                                          numberFormat.format((tweet.retweetCount ?? 0) + (tweet.quoteCount ?? 0))),
                                    if (tweet.favoriteCount != null)
                                      _createFooterTextButton(
                                          Symbols.favorite_border, numberFormat.format(tweet.favoriteCount)),
                                    const SizedBox(
                                      width: 8.0,
                                    ),
                                    Consumer<SavedTweetModel>(builder: (context, model, child) {
                                      var isSaved = model.isSaved(tweet.idStr!);
                                      if (isSaved) {
                                        return _createFooterIconButton(Symbols.bookmark, null, 1, () async {
                                          await model.deleteSavedTweet(tweet.idStr!);
                                          if (mounted) {
                                            setState(() {});
                                          }
                                          else {
                                            DataService().map['toggleRefreshFeed'] = true;
                                          }
                                        });
                                      } else {
                                        return _createFooterIconButton(Symbols.bookmark, null, 0, () async {
                                          await model.saveTweet(tweet.idStr!, tweet.user?.idStr, tweet.toJson());
                                          setState(() {});
                                        });
                                      }
                                    }),
                                    translateButton,
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ))
                    ],
                  ),
                ))));
  }
}

class TweetHasNoContentException {
  final String? id;

  TweetHasNoContentException(this.id);

  @override
  String toString() {
    return 'The tweet has no content {id: $id}';
  }
}

class _TweetTileLeading extends StatelessWidget {
  final Function()? onTap;
  final IconData icon;
  final Iterable<InlineSpan> children;

  const _TweetTileLeading({Key? key, this.onTap, required this.icon, required this.children}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      child: InkWell(
        onTap: onTap,
        child: Container(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.only(bottom: 0, left: 52, right: 16, top: 0),
          child: RichText(
            text: TextSpan(children: [
              WidgetSpan(
                  child: Icon(icon, size: 12, color: Theme.of(context).hintColor),
                  alignment: PlaceholderAlignment.middle),
              const WidgetSpan(child: SizedBox(width: 16)),
              ...children
            ]),
          ),
        ),
      ),
    );
  }
}

class TweetTextPart {
  final InlineSpan? entity;
  String? plainText;

  TweetTextPart(this.entity, this.plainText);

  @override
  String toString() {
    return plainText ?? '';
  }
}

class VisiblePositionState {
  bool initialized = false;
  String? visibleChainId;
  String? visibleTweetId;
  int? visibleTweetIdx;
  int? scrollChainIdx;
  int? scrollTweetIdx;

  VisiblePositionState();

  void positionChanged(String? visibleChainId, String? visibleTweetId, int? visibleTweetIdx) {
    this.visibleChainId = visibleChainId;
    this.visibleTweetId = visibleTweetId;
    this.visibleTweetIdx = visibleTweetIdx;
    initialized = true;
  }
}

enum TranslationStatus { original, translating, translationFailed, translated }
