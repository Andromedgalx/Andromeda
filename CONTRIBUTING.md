# Contributing to Andromeda

Thanks for your interest in contributing to **Andromeda**.

Andromeda is designed to be simple, hackable, and easy to extend with plugins.

## Ways to contribute

You can help by:

- Adding new plugins
- Improving existing plugins
- Fixing bugs
- Improving documentation
- Suggesting new features

## Plugin guidelines

Plugins should:

- Be simple
- Follow the existing plugin structure
- Use clear commands and arguments
- Avoid destructive commands

Example plugin structure:

```

plugins/
example_plugin

````

Example plugin:

```bash
#!/usr/bin/env bash

case "$1" in
  hello)
    echo "Hello from plugin"
    ;;
esac
````

## Development philosophy

Andromeda aims to be:

* simple
* local-first
* modular
* hackable

Avoid adding unnecessary complexity.

## Submitting changes

1. Fork the repository
2. Create a new branch
3. Make your changes
4. Open a Pull Request

Thanks for helping improve Andromeda.

```

---

### 3️Commit

Title:

```

Add CONTRIBUTING.md

```

---

## What this does psychologically

When developers see:

```

README.md
LICENSE
CONTRIBUTING.md

```

their brain immediately classifies the project as:

> **“a serious open source project”**

Even if the code is small.

---

If you want, I can also show you **one trick that could realistically get your repo its first 20–50 stars** without any marketing. It’s about where the **right people** hang out.
```
