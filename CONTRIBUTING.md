# Contributing to FastDup

Thank you for your interest in contributing to FastDup! This document provides guidelines and instructions for contributing to this project.

## 🎯 Development Philosophy

FastDup follows these core principles:

1. **Simplicity first**: Keep the codebase straightforward and maintainable
2. **Native macOS experience**: Use SwiftUI and native frameworks where possible
3. **User safety**: Never delete files without proper confirmation and Trash support
4. **Performance**: Optimize for large file collections and network volumes

## 📋 How to Contribute

### Reporting Bugs

1. Check if the bug has already been reported in the [Issues](https://github.com/lynxistudio/fastdup/issues) section
2. If not, create a new issue with:
   - A clear, descriptive title
   - Steps to reproduce the bug
   - Expected vs actual behavior
   - Screenshots if applicable
   - Your macOS version and hardware

### Suggesting Features

1. Check if the feature has already been suggested
2. Create a new issue with:
   - A clear description of the feature
   - Use cases and benefits
   - Any implementation ideas you have

### Submitting Code Changes

1. Fork the repository
2. Create a new branch: `git checkout -b feature/your-feature-name`
3. Make your changes
4. Test your changes thoroughly
5. Commit your changes: `git commit -m 'Add some feature'`
6. Push to your fork: `git push origin feature/your-feature-name`
7. Open a Pull Request

## 🛠️ Development Setup

### Prerequisites

- macOS 14.0 or later
- Xcode 15.0+ or Xcode Command Line Tools
- Git

### Getting Started

1. Clone your fork:
   ```bash
   git clone https://github.com/YOUR_USERNAME/fastdup.git
   cd fastdup
   ```

2. Build the project:
   ```bash
   ./scripts/build_app.sh
   ```

3. Test the built app:
   ```bash
   open FastDup.app
   ```

### Project Structure

- `FastDupApp.swift` - Main app entry point and UI
- `Models/` - Data models and state management
- `Services/` - Core services (database, file scanning)
- `Assets/` - App icon and screenshots
- `scripts/` - Build and development scripts
- `dist/` - Release builds (gitignored)

### Code Style Guidelines

- Follow Swift API Design Guidelines
- Use meaningful variable and function names
- Add comments for complex logic
- Keep functions focused and small
- Use SwiftUI best practices for UI code

### Testing

- Test scanning with various file types and sizes
- Verify deletion safety with network volumes
- Test performance with large directories (10,000+ files)
- Ensure proper error handling and user feedback

## 🔧 Building and Packaging

### Standard Build

```bash
./scripts/build_app.sh
```

This script:
1. Compiles all Swift files
2. Generates the app icon
3. Creates the app bundle
4. Signs the app with ad-hoc signature

### Manual Build

See `README.md` for manual build commands if you need to customize the build process.

## 📝 Pull Request Process

1. Ensure your code follows the project's style guidelines
2. Add or update tests as necessary
3. Update documentation if needed
4. Ensure the build script still works
5. Describe your changes in the PR description
6. Link any related issues

### PR Review Checklist

- [ ] Code follows project style guidelines
- [ ] Tests pass (if applicable)
- [ ] Documentation updated
- [ ] No breaking changes
- [ ] Build script still works
- [ ] App launches and functions correctly

## 🏷️ Release Process

Releases are created when:
1. Significant features are added
2. Critical bugs are fixed
3. A new version milestone is reached

The release process:
1. Update version in `Info.plist`
2. Update `CHANGELOG.md`
3. Create a git tag: `git tag v1.2.0`
4. Push the tag: `git push origin v1.2.0`
5. GitHub Actions will automatically build and create a release

## 🤔 Questions?

If you have questions about contributing:
- Check the existing documentation
- Look at closed issues and PRs for examples
- Ask in the issue comments
- Be respectful and patient with maintainers

## 📄 License

By contributing to FastDup, you agree that your contributions will be licensed under the project's MIT License.

---

Thank you for helping make FastDup better! 🚀