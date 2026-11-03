# Plotter — a native macOS function plotter

Plotter draws functions typed in LaTeX: curves y = f(x) in a 2D graph and
surfaces z = f(x, y) in a 3D graph. Each function has its own LaTeX box in the
sidebar. Above the box the formula is shown typeset, with its name (for example
*f(x) = sin x*), and the graph's legend shows the same typeset formulas.

![App icon](Icon/AppIcon.png)

## Using the app

| Action | 2D graph | 3D graph |
|---|---|---|
| Move / rotate | drag, or two-finger scroll | drag, or two-finger scroll |
| Zoom | pinch, mouse wheel, ⌘-scroll, ⌘+ / ⌘− | pinch, mouse wheel, ⌘+ / ⌘− |
| Reset the view | double-click, or ⌘0 | double-click, or ⌘0 |
| Read a value | hover over a curve | — |

- **⌘N** adds a function, **⌘1** / **⌘2** switch between the 2D and the 3D graph.
- The eye button hides a function; the coloured dot changes its colour;
  right-click a row to duplicate it, copy its LaTeX or delete it.
- Any letter other than x, y (and t, θ) is a **parameter** and gets a slider,
  e.g. `a\sin(kx)`.
- The toolbar's options button sets the 3D domain, resolution, colours
  (viridis, magma or the function's colour) and mesh lines.
- Functions and settings are saved automatically and restored at launch.

### What you can type

| Input | Meaning |
|---|---|
| `\sin x`, `y = x^2`, `f(x) = e^{-x^2}` | a curve in the 2D graph |
| `x^2 + y^2`, `z = \sin x \cos y`, `g(x, y) = xy` | a surface in the 3D graph |
| `\frac{a}{b}`, `\sqrt{x}`, `\sqrt[3]{x}`, `x^{2}`, `x^2`, `a_1` | fractions, roots, powers, subscripts |
| `\sin \cos \tan \cot \sec \csc`, `\arcsin \arccos \arctan`, `\sinh \cosh \tanh` | trigonometric and hyperbolic functions |
| `\exp`, `\ln`, `\log` (base 10), `\log_{2}` | exponential and logarithms |
| `\pi`, `e`, `\infty`, Greek letters (`\alpha` … `\omega`) | constants and parameters |
| `\cdot`, `\times`, `*`, `/`, implicit products (`2x`, `x\sin x`, `(x+1)(x-1)`) | multiplication and division |
| `\left( … \right)`, `[ … ]`, `|x|`, `\lfloor x \rfloor`, `\lceil x \rceil`, `x!` | brackets, absolute value, floor, ceiling, factorial |
| `\max(x, 0)`, `\min(…)`, `\operatorname{sgn} x` | further functions |

Conventions: `-x^2` is −(x²); `2^3^2` is 2^(3²); `\sin x^2` is sin(x²);
`\sin 2x \cos x` is sin(2x)·cos(x); `\sin^2 x` is (sin x)²; `\sin^{-1} x` is
arcsin x; as in TeX, an unbraced exponent is one character, so `x^23` is x²·3.
Undefined points (such as √x for x < 0) are left out of the graph; poles and
jumps (tan x, 1/x, ⌊x⌋) are not joined by vertical lines.

If the LaTeX cannot be read, the box turns red, the message says why and the
offending characters are marked; the graph keeps the last valid version.

## Building on a Mac

Requirements: **macOS 26** (Liquid Glass) and Xcode 26 or its Command Line Tools.
No Xcode project is needed.

```sh
cd Plotter
./build.sh --test --open   # runs the math tests, builds build/Plotter.app and opens it
```

The GitHub workflow `.github/workflows/build-plotter.yml` runs the same build on a
macOS runner for every push and uploads **Plotter-macOS** (the zipped app) and
**Plotter-screenshots**. Like Hello, the app is ad-hoc signed: open it once via
**System Settings → Privacy & Security → Open Anyway**, or run
`xattr -dr com.apple.quarantine Plotter.app`.

## How it works

| Path | Purpose |
|---|---|
| `Sources/Math/Lexer.swift` | LaTeX tokenizer (also accepts π, θ, ·, ×, − typed directly) |
| `Sources/Math/Parser.swift` | recursive-descent parser → syntax tree; classifies curve / surface, finds parameters |
| `Sources/Math/Compiler.swift` | compiles the tree into closures with constant folding; domain errors give NaN |
| `Sources/Math/Sampling.swift` | adaptive curve sampling with discontinuity detection, surface grids, 1-2-5 axis ticks |
| `Sources/App/Typesetter.swift` | TeX-style typesetting (atom spacing, scripts, fractions, radicals, stretchy brackets) in STIX Two |
| `Sources/App/Plot2DView.swift` | 2D graph (SwiftUI Canvas), pan / zoom / hover |
| `Sources/App/Plot3DView.swift` | 3D graph (Metal): lit surface mesh, colormaps, mesh lines, labelled box, orbit camera with inertia |
| `Sources/App/Sidebar.swift`, `ContentView.swift`, `Model.swift`, `PlotterApp.swift` | window, sidebar, toolbar, glass overlays, state and persistence |
| `Tests/main.swift` | about 170 checks of the parser, evaluator, samplers and labels (`./build.sh --test`) |
| `Icon/make_icon.py` | regenerates the icon (needs Pillow and NumPy) |

The math engine (`Sources/Math`) uses only Foundation.
