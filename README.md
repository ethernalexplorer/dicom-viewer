# DICOM Viewer for Windows

A lightweight Flutter desktop application for viewing uncompressed monochrome
DICOM studies on Windows.

## Features

- automatic discovery next to the executable and one directory above it;
- support for DICOM files with and without a `.dcm` extension;
- Explicit VR Little Endian, Implicit VR Little Endian and Explicit VR Big Endian;
- grouping and selection of series;
- mouse-wheel slice navigation;
- pointer-centered zoom with `Ctrl` + mouse wheel;
- panning, brightness, contrast and view reset;
- DICOM information overlay.

## Important medical notice

This software is intended solely for viewing images for informational purposes.
It does not diagnose disease, provide a medical opinion, replace diagnostic
workstations or substitute for consultation with a qualified healthcare
professional. Do not make medical decisions based solely on this software.

## Build

Requirements:

- Flutter stable with Windows desktop support;
- Visual Studio with Desktop development with C++ workload;
- Windows 10 or newer for building.

```powershell
flutter pub get
flutter build windows --release
```

The distribution is generated under
`build/windows/x64/runner/Release`. Keep the executable,
`flutter_windows.dll` and the complete `data` directory together.

## Privacy

DICOM studies can contain sensitive health and personal data. Never commit
patient files, screenshots containing patient identifiers, DICOM tag dumps or
release archives containing studies to a public repository.

## License

The published source code is available under the MIT License. See `LICENSE`.
Third-party notices are documented in `THIRD_PARTY_NOTICES.md` and generated
by Flutter in the release bundle.

Organization names, logos, icons and other trademarks are not licensed under
the MIT License and must not be included in a public fork without permission.
