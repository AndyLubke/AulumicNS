# Third-party notices

Aulumic (AulumicNS) is Copyright © 2026 André Lubke and licensed under the GNU General Public License, version 3 (see `LICENSE`). It contains or uses the following work of others.

## AulumicTag (a fork of OvoTag)

- Where: `src\tags`
- Copyright © 2011 Marco Caselli (OvoTag); changes for Aulumic © 2026 André Lubke.
- Licence: GNU Library General Public License, version 2 or later, with the linking exception known as the "FPC modified LGPL". The full texts are in `src\tags\COPYING.LGPL.txt` and `src\tags\COPYING.modifiedLGPL.txt`; `src\tags\README.md` lists the changes.
- Source of the original: https://github.com/varianus/ovotag

The comment at the top of these units still carries the GNU General Public License text of OvoPlayer, the player the library was taken out of. That is so in the original repository too; its README and the two COPYING files state the modified LGPL. The headers are left as they are.

## ID3v1 genre list (from h0td0g)

- Where: `src\tags\id3v1genres.pas` (came with OvoTag)
- Copyright © 2003-2008 George Poulios.
- Licence: GNU General Public License, version 2 or later (the notice is at the top of the file). Aulumic uses it under version 3.

## Lazarus Component Library (LCL) and the Free Pascal run-time library

- Linked into the program file; not part of this repository.
- Licence: GNU Library General Public License with a linking exception (modified LGPL).
- https://www.lazarus-ide.org/ and https://www.freepascal.org/

## ASIO

ASIO is a trademark and software of Steinberg Media Technologies GmbH.

Aulumic talks to ASIO drivers through interface declarations written in Pascal (`src\audio\ALOutputAsio.pas`). The ASIO SDK is available from Steinberg under a dual licence: a proprietary agreement or the GNU General Public License, version 3. Aulumic is published under the GPLv3.

## Online services

Artist Info shows biographies and pictures from Last.fm, Wikipedia and TheAudioDB, subject to the terms of these services. The artist's name is sent to them. No API key is built into the program: the Last.fm key is the user's own.

## Windows components

The program uses Direct2D, DirectWrite, the Windows Imaging Component, WASAPI and the PDF engine of Windows (Windows.Data.Pdf) through the interfaces of the operating system. Nothing of them is distributed with Aulumic.
