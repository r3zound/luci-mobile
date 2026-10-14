class AppConfig {
  /// Where this build comes from, and where its updates will be published.
  ///
  /// The About dialog links here, so this is the one line to change when the
  /// project moves - nothing else in the app hard-codes a repository address.
  static const String githubRepositoryUrl =
      'https://github.com/r3zound/luci-mobile';

  // GitHub issues URL
  static const String githubIssuesUrl = '$githubRepositoryUrl/issues';

  // Reviewer mode configuration
  static const String reviewerModeKey = 'reviewer_mode_enabled';
  static const String mockDataPath = 'assets/mock/';
  static const Duration reviewerModeActivationDuration = Duration(seconds: 5);
  static const String reviewerModeWatermark = 'Reviewer Mode';
}
