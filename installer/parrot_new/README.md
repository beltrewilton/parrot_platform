# Parrot New

Generators for creating new Parrot Platform applications.

## Installation

```bash
mix archive.install hex parrot_new
```

Or from GitHub before Hex publication:

```bash
# Clone the repository
git clone https://github.com/parrot-platform/parrot_platform.git
cd parrot/installer/parrot_new
mix archive.build
mix archive.install ./parrot_new-0.0.1-alpha.3.ez
```

## Usage

### Generate a UAC (User Agent Client) application:

```bash
mix parrot.gen.uac my_uac_app
cd my_uac_app
mix deps.get
iex -S mix
```

### Generate a UAS (User Agent Server) application:

```bash
mix parrot.gen.uas my_uas_app
cd my_uas_app
mix deps.get
iex -S mix
```

## Options

Both generators support options:

- `--port` - Specify the SIP port (default: 5060 for UAS, 5070 for UAC)
- `--module` - Specify the module name (default: derived from app name)
- `--dev` - Use path dependencies for local development (see Development section)

Example:
```bash
mix parrot.gen.uac my_app --module MyCompany.VoiceApp --port 5080
```

## Development

For contributors working on the parrot_platform source code, use the `--dev` flag to generate apps with path dependencies instead of Hex dependencies:

```bash
# Generate app next to your parrot_platform checkout
cd /path/to/your/projects
mix parrot.gen.uas my_test_uas --dev

# The generated mix.exs will use:
# {:parrot_sip, path: "../parrot_platform/apps/parrot_sip"}
# instead of:
# {:parrot_sip, "~> 0.0.1"}
```

**Important:** The `--dev` flag assumes parrot_platform is in a sibling directory. Adjust the paths in the generated `mix.exs` if your directory structure differs.

### Rebuilding the Archive

After making changes to the generators:

```bash
cd installer/parrot_new
mix archive.uninstall parrot_new
mix archive.build
mix archive.install
```

## About

These generators create complete Parrot Platform applications with:

- SIP protocol support (UAC or UAS)
- Optional audio device integration
- G.711 A-law codec support
- Example code and documentation
- Test files

For more information about Parrot Platform, visit: https://github.com/parrot-platform/parrot_platform
