# Render the all-contributors table into the file named in `files`, byte
# for byte the way `all-contributors-cli generate` (6.26.1) does with its
# default templates, so the table can be regenerated without installing
# the CLI and its npm dependency tree.
#
# Input:  .all-contributorsrc
# Args:   --rawfile file <the one file in .files, README.md by default>
# Output: the new text of that file (use jq -j)
#
# Options the CLI supports but this does not (custom templates, extra
# types, alphabetical sort, usage footer, object contributions, the badge
# section, other repo types, more than one file, unusual marker placement)
# fail loudly instead of rendering something different.

# Contribution types exported from all-contributors-cli 6.26.1
# (dist/util/contribution-types.js): symbol, description, link kind.
def types:
{"a11y":{"s":"️️️️♿️","d":"Accessibility","l":null},"audio":{"s":"🔊","d":"Audio","l":null},"blog":{"s":"📝","d":"Blogposts","l":null},"bug":{"s":"🐛","d":"Bug reports","l":"issues"},"business":{"s":"💼","d":"Business development","l":null},"code":{"s":"💻","d":"Code","l":"commits"},"content":{"s":"🖋","d":"Content","l":null},"data":{"s":"🔣","d":"Data","l":null},"design":{"s":"🎨","d":"Design","l":null},"doc":{"s":"📖","d":"Documentation","l":"commits"},"eventOrganizing":{"s":"📋","d":"Event Organizing","l":null},"example":{"s":"💡","d":"Examples","l":null},"financial":{"s":"💵","d":"Financial","l":null},"fundingFinding":{"s":"🔍","d":"Funding Finding","l":null},"ideas":{"s":"🤔","d":"Ideas, Planning, & Feedback","l":null},"infra":{"s":"🚇","d":"Infrastructure (Hosting, Build-Tools, etc)","l":null},"maintenance":{"s":"🚧","d":"Maintenance","l":null},"mentoring":{"s":"🧑‍🏫","d":"Mentoring","l":null},"platform":{"s":"📦","d":"Packaging/porting to new platform","l":null},"plugin":{"s":"🔌","d":"Plugin/utility libraries","l":null},"projectManagement":{"s":"📆","d":"Project Management","l":null},"question":{"s":"💬","d":"Answering Questions","l":null},"research":{"s":"🔬","d":"Research","l":null},"review":{"s":"👀","d":"Reviewed Pull Requests","l":"reviews"},"security":{"s":"🛡️","d":"Security","l":null},"talk":{"s":"📢","d":"Talks","l":null},"test":{"s":"⚠️","d":"Tests","l":"commits"},"tool":{"s":"🔧","d":"Tools","l":null},"translation":{"s":"🌍","d":"Translation","l":null},"tutorial":{"s":"✅","d":"Tutorials","l":null},"userTesting":{"s":"📓","d":"User Testing","l":null},"video":{"s":"📹","d":"Videos","l":null},"promotion":{"s":"📣","d":"Promotion","l":null}};

def esc: gsub("\\|"; "&#124;") | gsub("\""; "&quot;");

def contribution($o; $c):
  . as $t
  | if type != "string" then error("only plain contribution types are supported, got \(tojson) for \($c.login)") else . end
  | types[$t] as $ty
  | if $ty == null then error("unknown contribution type \($t) for \($c.login)") else . end
  # JS `||`: an empty repoHost also falls back to github.com.
  | "\(if ($o.repoHost // "") == "" then "https://github.com" else $o.repoHost end)/\($o.projectOwner)/\($o.projectName)" as $repo
  | (if $ty.l == "commits" then "\($repo)/commits?author=\($c.login)"
     elif $ty.l == "issues" then "\($repo)/issues?q=author%3A\($c.login)"
     elif $ty.l == "reviews" then "\($repo)/pulls?q=is%3Apr+reviewed-by%3A\($c.login)"
     else "#\($t)-\($c.login)" end) as $url
  | "<a href=\"\($url)\" title=\"\($ty.d)\">\($ty.s)</a>";

def cell($o):
  . as $c
  # lodash `assign({imageSize: 100}, options)`: only a missing key gets the
  # default; an explicit null renders empty, as the template prints it.
  | (if $o | has("imageSize") then ($o.imageSize // "") else 100 end) as $size
  | ((if (.name // "") == "" then .login else .name end) | esc) as $name
  | "<img src=\"\(.avatar_url // "")?s=\($size)\" width=\"\($size)px;\" alt=\"\($name)\"/>" as $avatar
  | (if (.profile // "") != ""
     then "<a href=\"\(.profile)\">\($avatar)<br /><sub><b>\($name)</b></sub></a>"
     else "\($avatar)<br /><sub><b>\($name)</b></sub>" end) as $block
  | ([.contributions[] | contribution($o; $c)] | join(" ")) as $contribs
  | "\($block)<br />\($contribs)";

def list($o):
  ($o.contributorsPerLine // 7) as $n
  | "align=\"center\" valign=\"top\" width=\"\((10000 / $n | floor) / 100)%\"" as $attr
  | [.contributors[] | cell($o)] as $cells
  | if ($cells | length) == 0 then "\n"
    else [range(0; $cells | length; $n) as $i
          | "<td \($attr)>" + ($cells[$i:$i + $n] | join("</td>\n      <td \($attr)>")) + "</td>"]
      | join("\n    </tr>\n    <tr>\n      ")
      | "\n<table>\n  <tbody>\n    <tr>\n      \(.)\n    </tr>\n  </tbody>\n</table>\n\n"
    end;

# Options are rejected only when they change the output: an explicit
# default (false, "", {}, []) renders the same as leaving it out.
def set: . != null and . != false and . != "" and . != {} and . != [];

. as $o
| ["contributorTemplate", "wrapperTemplate", "types", "contributorsSortAlphabetically", "badgeTemplate", "linkToUsage"]
  | map(select($o[.] | set)) as $unsupported
| if ($unsupported | length) > 0 then error("unsupported options: \($unsupported | join(", "))") else . end
| if (($o.repoType // "github") != "github") then error("only repoType github is supported") else . end
| if (($o.files // ["README.md"]) | length) != 1 then error("exactly one entry in files is supported") else . end
| if ($file | contains("<!-- ALL-CONTRIBUTORS-BADGE:START")) then error("the badge section is not supported") else . end
# The CLI splices at the first marker occurrence anywhere and indents by its
# column; requiring exactly one pair, START at the start of a line, keeps
# the two from picking different places.
| if ([$file | match("<!-- ALL-CONTRIBUTORS-LIST:START"; "g")] | length) != 1
     or ([$file | match("<!-- ALL-CONTRIBUTORS-LIST:END"; "g")] | length) != 1
  then error("the file needs exactly one ALL-CONTRIBUTORS-LIST START and END marker") else . end
| ($file | capture("^(?<pre>[\\s\\S]*?\n<!-- ALL-CONTRIBUTORS-LIST:START[^\n]*?-->)(?<mid>[\\s\\S]*?)(?<post><!-- ALL-CONTRIBUTORS-LIST:END[\\s\\S]*)$")
  // error("the ALL-CONTRIBUTORS-LIST START marker must open a line and close on it, before END")) as $m
| $m.pre
  + "\n<!-- prettier-ignore-start -->\n<!-- markdownlint-disable -->"
  + ($o | list($o))
  + "<!-- markdownlint-restore -->\n<!-- prettier-ignore-end -->\n\n"
  + $m.post
