import 'package:flutter/material.dart';
import '../../../app/localization/app_localizations.dart';

/// Page de consultation des Conditions Générales d'Utilisation de VT NUM.
///
/// Cette page peut être affichée depuis le formulaire d'inscription
/// avec : const TermsConditionsPage()
///
/// L'acceptation obligatoire des CGU reste gérée par auth_gate.dart.
class TermsConditionsPage extends StatelessWidget {
  const TermsConditionsPage({super.key});

  static const Color _primaryColor = Color(0xFF1565C0);
  static const Color _backgroundColor = Color(0xFFF5F7FB);

  static const List<_TermsArticle> _articles = [
    _TermsArticle(
      title: 'article_1_title',
      paragraphs: ['article_1_paragraph_1',
        'article_1_paragraph_2',
        'article_1_paragraph_3'],
    ),
    _TermsArticle(
      title: 'article_2_title',
      paragraphs: ['article_2_paragraph_1',
        'article_2_paragraph_2',
        'article_2_paragraph_3'],
    ),
    _TermsArticle(
      title: 'article_3_title',
      paragraphs: ['article_3_paragraph_1',
        'article_3_paragraph_2',
        'article_3_paragraph_3'],
    ),
    _TermsArticle(
      title: 'article_4_title',
      paragraphs: ['article_4_paragraph_1'],
      bullets: ['article_4_bullet_1',
        'article_4_bullet_2',
        'article_4_bullet_3',
        'article_4_bullet_4',
        'article_4_bullet_5',
        'article_4_bullet_6',
        'article_4_bullet_7'],
      conclusion: 'article_4_conclusion',
    ),
    _TermsArticle(
      title: 'article_5_title',
      paragraphs: ['article_5_paragraph_1',
        'article_5_paragraph_2',
        'article_5_paragraph_3',
        'article_5_paragraph_4',
        'article_5_paragraph_5'],
    ),
    _TermsArticle(
      title: 'article_6_title',
      paragraphs: ['article_6_paragraph_1',
        'article_6_paragraph_2',
        'article_6_paragraph_3',
        'article_6_paragraph_4'],
    ),
    _TermsArticle(
      title: 'article_7_title',
      paragraphs: ['article_7_paragraph_1',
        'article_7_paragraph_2',
        'article_7_paragraph_3',
        'article_7_paragraph_4',
        'article_7_paragraph_5'],
    ),
    _TermsArticle(
      title: 'article_8_title',
      paragraphs: ['article_8_paragraph_1',
        'article_8_paragraph_2',
        'article_8_paragraph_3',
        'article_8_paragraph_4'],
    ),
    _TermsArticle(
      title: 'article_9_title',
      paragraphs: ['article_9_paragraph_1',
        'article_9_paragraph_2',
        'article_9_paragraph_3',
        'article_9_paragraph_4',
        'article_9_paragraph_5'],
    ),
    _TermsArticle(
      title: 'article_10_title',
      paragraphs: ['article_10_paragraph_1',
        'article_10_paragraph_2',
        'article_10_paragraph_3',
        'article_10_paragraph_4'],
    ),
    _TermsArticle(
      title: 'article_11_title',
      paragraphs: ['article_11_paragraph_1',
        'article_11_paragraph_2',
        'article_11_paragraph_3'],
    ),
    _TermsArticle(
      title: 'article_12_title',
      paragraphs: ['article_12_paragraph_1',
        'article_12_paragraph_2',
        'article_12_paragraph_3'],
    ),
    _TermsArticle(
      title: 'article_13_title',
      paragraphs: ['article_13_paragraph_1',
        'article_13_paragraph_2',
        'article_13_paragraph_3',
        'article_13_paragraph_4',
        'article_13_paragraph_5'],
    ),
    _TermsArticle(
      title: 'article_14_title',
      paragraphs: ['article_14_paragraph_1'],
    ),
    _TermsArticle(
      title: 'article_15_title',
      paragraphs: ['article_15_paragraph_1',
        'article_15_paragraph_2',
        'article_15_paragraph_3',
        'article_15_paragraph_4',
        'article_15_paragraph_5'],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _backgroundColor,
      appBar: AppBar(
        title: Text(
          context.strings.text('terms.app_bar_title'),
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        backgroundColor: _primaryColor,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
      ),
      body: SafeArea(
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: _buildHeader(context),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final article = _articles[index];

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _buildArticle(
                        context,
                        article,
                        index + 1,
                      ),
                    );
                  },
                  childCount: _articles.length,
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: Colors.blue.shade100,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        color: Colors.blue.shade700,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          context.strings.text('terms.read_before_accepting'),
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.6,
                            color: Color(0xFF334155),
                          ),
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

  Widget _buildHeader(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 26),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Color(0xFF1565C0),
            Color(0xFF0D47A1),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(24),
          bottomRight: Radius.circular(24),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(15),
            ),
            child: const Icon(
              Icons.gavel_rounded,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            context.strings.text('terms.header_title'),
            style: TextStyle(
              color: Colors.white,
              fontSize: 23,
              height: 1.3,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'VT NUM',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9),
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.2),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.menu_book_rounded,
                  size: 17,
                  color: Colors.white,
                ),
                SizedBox(width: 8),
                Text(
                  context.strings.text('terms.articles_count'),
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildArticle(BuildContext context, _TermsArticle article, int number) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFFE5EAF2),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.025),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F1FD),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  number.toString().padLeft(2, '0'),
                  style: const TextStyle(
                    color: _primaryColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Text(
                    context.strings.text('terms.${article.title}'),
                    style: const TextStyle(
                      fontSize: 15,
                      height: 1.4,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF172033),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ...article.paragraphs.map(
            (paragraph) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                context.strings.text('terms.$paragraph'),
                textAlign: TextAlign.start,
                style: const TextStyle(
                  fontSize: 13.5,
                  height: 1.75,
                  color: Color(0xFF475569),
                ),
              ),
            ),
          ),
          if (article.bullets.isNotEmpty) ...[
            const SizedBox(height: 2),
            ...article.bullets.map(
              (bullet) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      margin: const EdgeInsets.only(top: 8, right: 10),
                      decoration: const BoxDecoration(
                        color: _primaryColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        context.strings.text('terms.$bullet'),
                        style: const TextStyle(
                          fontSize: 13.5,
                          height: 1.7,
                          color: Color(0xFF475569),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (article.conclusion != null) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF5F7FB),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                context.strings.text('terms.${article.conclusion!}'),
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.7,
                  fontStyle: FontStyle.italic,
                  color: Color(0xFF475569),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TermsArticle {
  final String title;
  final List<String> paragraphs;
  final List<String> bullets;
  final String? conclusion;

  const _TermsArticle({
    required this.title,
    this.paragraphs = const [],
    this.bullets = const [],
    this.conclusion,
  });
}
