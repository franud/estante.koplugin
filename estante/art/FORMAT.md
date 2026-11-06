# Estante sleep-screen art format

Each `*.txt` file in this folder holds many drawings. One is shown at the bottom of the
sleep screen, picked from a shuffle bag (every drawing shows once before any repeats).

Rules (enforced by `tools/check-art.py`):

- A drawing starts with a title line `# Some title` and ends with a line containing only `%%`.
- Printable ASCII only (characters 32–126). No tabs, no Unicode.
- Max **50 columns** wide, max **11 lines** tall (title and `%%` lines not counted).
- Min 4 lines tall. Leading indentation is fine (the common indent is stripped and the block is centred).
- Must be an original drawing (no copies of known ASCII-art pieces or signatures).
- Calm "falling asleep / quiet moment" mood fits best, but any gentle, pretty subject works.

Example:

```
# cat on a stack of books
              /\_/\     z
             ( -.- )  Z
        _____/ > < \__________
       |  __________________  |
       |_|__________________|_|
      |  ===  =====  ===  ==  |
      |_______________________|
%%
```

You can add your own file here (e.g. `mine.txt`), or on the device in
`koreader/settings/estante-art.txt` (that one survives plugin updates).
