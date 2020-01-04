import macros

dumpTree:
    ircCommand commandName:
        customRegex: "regex"            # not required
        alias:
            # allow either re"" or ""
            # 
            ["regex1", re"regex2"]     # not required
        help:
            # assign StmtList to a new proc
            result = "generate help text here"
        proc routine(match, msg, user, channel: string): Future[string] {.async.} =
            result = "generate result of running command"
        requireOP: false                # defaults to false
        enabledByDefault: true          # defaults to true
        opOnlyByDefault: false          # defaults to false

static:
    echo "------------------------"

dumpTree:
    proc routine(match, msg, user, channel: string): Future[string] {.async.} =
        echo "testing"

static:
    echo "------------------------"

dumpTree:
    let cmdProc = proc (match, msg, user, channel: string): Future[string] {.async.} =
        echo "testing"
