# Render a one-row preview of the contributors table into README.md: the
# first N entries of .all-contributorsrc as small linked avatars, then a
# link to the full table for the rest. N comes from the START marker
# (`<!-- CONTRIBUTORS-PREVIEW:START count=14 ... -->`), so it lives in one
# place. Who is shown follows the order in .all-contributorsrc, which
# scripts/update-contributors.sh keeps sorted by activity.
#
# Input:  .all-contributorsrc
# Args:   --rawfile file README.md --arg table CONTRIBUTORS.md
# Output: the new README text (use jq -j)
#
# Not part of the all-contributors spec: it uses its own marker pair, which
# all-contributors-cli leaves alone. Escaping is stricter than the table
# renderer's on purpose: that one has to match the CLI byte for byte.

def esc: gsub("&"; "&amp;") | gsub("\""; "&quot;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");

# GitHub avatar URLs already carry a query (?v=4); a second "?" would make
# GitHub ignore the size and serve the full image.
def sized($px):
  if test("[?&]s=") then .
  else . + (if contains("?") then "&" else "?" end) + "s=\($px)" end;

# An entry without an avatar (e.g. added by hand) shows its name instead of
# a broken image.
def avatar:
  ((if (.name // "") == "" then (.login // "") else .name end) | esc) as $name
  | (if (.avatar_url // "") == "" then $name
     else "<img src=\"\(.avatar_url | sized(80) | esc)\" width=\"40\" height=\"40\" alt=\"\($name)\" title=\"\($name)\"/>"
     end) as $img
  | if (.profile // "") != "" then "<a href=\"\(.profile | esc)\">\($img)</a>" else $img end;

. as $o
| if ([$file | match("<!-- CONTRIBUTORS-PREVIEW:START"; "g")] | length) != 1
     or ([$file | match("<!-- CONTRIBUTORS-PREVIEW:END"; "g")] | length) != 1
  then error("README needs exactly one CONTRIBUTORS-PREVIEW START and END marker") else . end
| ($file | capture("^(?<pre>(?:[\\s\\S]*?\n)?<!-- CONTRIBUTORS-PREVIEW:START(?<attrs>[^\n]*?)-->)(?<mid>[\\s\\S]*?)(?<post><!-- CONTRIBUTORS-PREVIEW:END[\\s\\S]*)$")
  // error("the CONTRIBUTORS-PREVIEW START marker must open a line and close on it, before END")) as $m
| ($m.attrs | capture("(^|\\s)count=(?<n>[0-9]+)(\\s|$)") // error("the START marker needs count=<number>") | .n | tonumber) as $n
| ($o.contributors | length) as $total
| ([$n, $total] | min) as $shown
| ($total - $shown) as $rest
| ([$o.contributors[:$shown][] | avatar] | join("\n")) as $avatars
# <...> keeps a link target with spaces or parentheses intact.
| (if $rest > 0 and $shown > 0 then "And [\($rest) more](<\($table)>), credited in full there."
   else "All of them are credited in [\($table)](<\($table)>)." end) as $more
| $m.pre + "\n" + (if $shown > 0 then $avatars + "\n\n" else "" end) + $more + "\n" + $m.post
