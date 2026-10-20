import { describe, expect, it } from 'vitest'
import { splitHunks } from '../../src/main/git'

const sample = `diff --git a/a.txt b/a.txt
index 1111111..2222222 100644
--- a/a.txt
+++ b/a.txt
@@ -1,3 +1,3 @@
 one
-two
+TWO
 three
@@ -10,2 +10,3 @@
 ten
+ten and a half
 eleven
`

describe('splitHunks', () => {
  it('returns the file header plus one entry per hunk', () => {
    const { header, hunks } = splitHunks(sample)
    expect(header).toContain('--- a/a.txt')
    expect(hunks).toHaveLength(2)
    expect(hunks[0]).toMatch(/^@@ -1,3 \+1,3 @@/)
    expect(hunks[1]).toMatch(/^@@ -10,2 \+10,3 @@/)
    expect(hunks[1].endsWith('\n')).toBe(false)
  })
  it('returns no hunks for an empty diff', () => {
    expect(splitHunks('').hunks).toEqual([])
  })
})
