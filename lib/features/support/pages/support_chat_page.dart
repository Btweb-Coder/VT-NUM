
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../app/localization/app_localizations.dart';

const _tawkChatUrl =
    'https://tawk.to/chat/6ae4c3d9cebe703474ce03f2/1k66pq2pr?layout=modern';

class SupportChatPage extends StatefulWidget {
  const SupportChatPage({
    super.key,
    required this.isVisible,
    required this.onClose,
  });

  final bool isVisible;
  final VoidCallback onClose;

  @override
  State<SupportChatPage> createState() => _SupportChatPageState();
}

class _SupportChatPageState extends State<SupportChatPage> {
  late final WebViewController _controller;

  bool _loading = true;
  bool _loadFailed = false;
  int _progress = 0;

  @override
  void initState() {
    super.initState();

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);

            if (uri == null ||
                (uri.scheme != 'https' &&
                    !(uri.scheme == 'about' && uri.path == 'blank'))) {
              return NavigationDecision.prevent;
            }

            return NavigationDecision.navigate;
          },
          onProgress: (progress) {
            if (!mounted) return;
            setState(() => _progress = progress);
          },
          onPageStarted: (_) {
            if (!mounted) return;

            setState(() {
              _loading = true;
              _loadFailed = false;
              _progress = 0;
            });
          },
          onPageFinished: (_) {
            if (!mounted) return;

            setState(() {
              _loading = false;
              _progress = 100;
            });
          },
          onWebResourceError: (error) {
            if (!mounted || error.isForMainFrame == false) return;

            setState(() {
              _loading = false;
              _loadFailed = true;
            });
          },
        ),
      );

    unawaited(_loadChat());
  }

  Future<void> _loadChat() async {
    try {
      await _controller.loadRequest(Uri.parse(_tawkChatUrl));
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  Future<void> _retry() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
      _progress = 0;
    });

    await _loadChat();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: !widget.isVisible,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && widget.isVisible) {
          widget.onClose();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: IconButton(
            onPressed: widget.onClose,
            icon: const Icon(Icons.arrow_back),
            tooltip: context.strings.text('common.close'),
          ),
          title: Text(context.strings.text('navigation.support')),
        ),
        body: Stack(
          children: [
            WebViewWidget(controller: _controller),

            if (_loading && !_loadFailed)
              Align(
                alignment: Alignment.topCenter,
                child: LinearProgressIndicator(
                  value: _progress == 0 ? null : _progress / 100,
                  minHeight: 2,
                ),
              ),

            if (_loadFailed)
              ColoredBox(
                color: Theme.of(context).scaffoldBackgroundColor,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.wifi_off_rounded, size: 42),
                        const SizedBox(height: 16),
                        Text(
                          context.strings.text('support.chat_load_error'),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _retry,
                          icon: const Icon(Icons.refresh),
                          label: Text(
                            context.strings.text('common.retry'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
