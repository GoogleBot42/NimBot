import nre
import irc
import algorithm
import tables
import strutils
import deques
import asyncdispatch
import strtabs
import strutils
import random
import httpclient
import json
import hashes
from unicode import utf8
from times import getTime, toUnix

type
  IrcFunc* = proc(match, msg, nick, channel: string): Future[string]
  IrcCommand* = ref object of RootObj
    name*, helpTxt*: string
    isCustomRegex*: bool
    regex*: Regex
    f*: IrcFunc
    hidden*: bool # if true, doesn't show up in command list
  IrcCommandRestrictions* = ref object of RootObj
    opOnly*: bool
    disabled*: bool

const
  botname = "NimBot"
  ircServerAddress = "irc.rizon.net"
  ircServerPort = 6667
  botChannel = "#NimBot"
  ircChannels = @[botChannel, "#dailyprog"]
  ircPassword = ""
  historySize = 256 # must be a power of two
  completionApi = "http://localhost:8888"
  objectDetectionApi = "http://localhost:8889"
  tswfApi = "https://stream.neet.space/api"
  maxMsgLen = 400 # max length of a single irc message
  msgSleep = 400 # time to sleep between sending multiple messages

var
  cmds = newSeq[IrcCommand]()
  cmdsByName = initTable[string, IrcCommand]()
  # cmd restrictions by channel
  cmdRestrictions = initTable[string, ref Table[string, IrcCommandRestrictions]]()
  regex: Regex # regex to match all possible commands
  history = initDeque[string](historySize)
  client: AsyncIrc
  r = initRand(getTime().toUnix)
  lastCompletionSeed = 0
  lastCompletionString = ""

proc buildPrimaryRegex(cmd: seq[IrcCommand]): Regex =
  var r = ""
  for i, cmd in cmds:
    if i > 0:
      r &= "|"
    r &= "(?<" & cmd.name & ">" & cmd.regex.pattern & ")"
  echo("Command matching regex: " & r)
  result = re(r)

proc findCommandMatches(regex: Regex, msg: string): Table[string,string] =
  let matches = msg.find(regex)
  if matches.isNone:
    result = initTable[string,string]()
  else:
    result = matches.get.captures.toTable
  echo result

proc isOP(nick, channel: string): bool =
  if channel == botname:
    # this is a private message
    return false
  let userList = client.getUserList(channel)
  for user in userList:
    if user.len == nick.len + 1 and user.endsWith(nick):
      let permission = user[0]
      return permission == '@' or permission == '%'
  return false

proc getCmdParam(match, msg: string): string =
  if msg.replace(match, "").strip == "":
    return history[0]
  else:
    return msg.replace(match, "").strip

proc getCmdRestrictions(cmdName, channel: string): IrcCommandRestrictions =
  if not cmdRestrictions.hasKey(channel):
    cmdRestrictions[channel] = newTable[string, IrcCommandRestrictions]()
  var channelRestrictions = cmdRestrictions[channel]
  if not channelRestrictions.hasKey(cmdName):
    channelRestrictions[cmdName] = IrcCommandRestrictions(opOnly: false, disabled: false)
  result = channelRestrictions[cmdName]

proc runCmdIfAllowed(cmdName, match, msg, user, channel: string): Future[string] {.async.} =
  let cmdRestrictions = getCmdRestrictions(cmdName, channel)
  if cmdRestrictions.disabled:
    result = "This command is disabled. An OP can enable it with \"" & botname & " enable " & cmdName & "\"."
    result &= " You can also visit " & botChannel & " where everything is enabled."
    return
  if cmdRestrictions.opOnly and not isOP(user, channel):
    return "This command can only be run by an OP. An OP can allow all users to use it with \"" & botname & " allowEveryone " & cmdName & "\"."
  result = await cmdsByName[cmdName].f(match, msg, user, channel)

template defineIrcCommand(match, msg, user, channel: untyped; cmdName: string; cmdRegex: Regex; cmdHelpTxt: string; hiddenCmd: bool; body: untyped) =
  let cmdProc = proc (match, msg, user, channel: string): Future[string] {.async.} =
    body
  let newCmd = IrcCommand(name: cmdName, regex: cmdRegex, helpTxt: cmdHelpTxt, f: cmdProc, isCustomRegex: true, hidden: hiddenCmd)
  cmds.add(newCmd)
  cmdsByName[newCmd.name] = newCmd

template defineIrcCommand(match, msg, user, channel: untyped; cmdName, cmdHelpTxt: string; body: untyped) =
  let completeRegex = re("(?i)^" & botname & " " & cmdName & "(?-i)")
  defineIrcCommand(match, msg, user, channel, cmdName, completeRegex, cmdHelpTxt, false, body)
  cmdsByName[cmdName].isCustomRegex = false

var aliasCounter = 0
template defineAlias(cmdName: string; aliasRegex: Regex) =
  let aliasCmdName = cmdName & "_alias__" & $aliasCounter
  inc aliasCounter
  defineIrcCommand(matchy, msg, user, channel, aliasCmdName, aliasRegex, "", hiddenCmd = true):
    return await runCmdIfAllowed(cmdName, matchy, msg, user, channel) # cannot call this match because of what i assume is a compiler bug

defineIrcCommand(match, msg, user, channel, "dothelp", re"^\.help$", "", hiddenCmd = true):
  result = "For help, type \"" & botname & " help\"."

defineIrcCommand(match, msg, user, channel, "help", "try '%BOTNAME% help <command>' to get help with a command.\nTo get a command list '%BOTNAME% commands'"):
  let cmdName = if msg == "": "help" else: msg
  if cmdsByName.hasKey(cmdName):
    let cmd = cmdsByName[cmdName]
    result = cmdName & ": " & cmd.helpTxt.replace("%BOTNAME%", botname)
  else:
    result = "No such command: " & msg

defineIrcCommand(match, msg, user, channel, "commands", "Lists all the available commands the irc bot supports"):
  for i, cmd in cmds:
    if cmd.hidden:
      continue
    if i > 0:
      result &= "\n"
    result &= cmd.name

defineIrcCommand(match, msg, user, channel, "desu", re"^desu$", "takes the last statement and appends desu at the end", hiddenCmd = false):
  result = history[0] & ", desu"

const faces = @["(・`ω´・)", ";;w;;", "owo", "UwU", ">w<", "^w^"]
defineIrcCommand(match, msg, user, channel, "owo", re"(?i)\b(owo|uwu|\^w\^)\b(?-i)", "OwOifies text", hiddenCmd = false):
  # taken from here: https://honk.moe/tools/owo.html
  result = if msg.replace(match, "").strip == "": history[0] else: msg
  result = result.replace(re"(?:r|l)", "w");
  result = result.replace(re"(?:R|L)", "W");
  result = result.replace(re"n([aeiou])", "ny$1");
  result = result.replace(re"N([aeiou])", "Ny$1");
  result = result.replace(re"N([AEIOU])", "Ny$1");
  result = result.replace(re"ove", "uv");
  result = result.replace(re"\!+", " " & r.sample(faces) & " ");

proc doCompletion(input: string; seed, length: int): Future[string] {.async.} =
  let completionHttpClient = newAsyncHttpClient()
  completionHttpClient.headers = newHttpHeaders({ "Content-Type": "application/json" })
  let body = %*{
    "query": input,
    "seed": seed,
    "length": length
  }
  let response = await completionHttpClient.request(completionApi, HttpPost, $body)
  result = await response.body
  completionHttpClient.close()
  result = result.replace(re"\s+", " ").strip
  result = "..." & result & "..."

defineIrcCommand(match, msg, user, channel, "complete", "Uses gpt-2 to complete a statement."):
  let input = if msg.replace(match, "").strip == "": history[0] else: msg
  let seed: int = r.rand(int.high)
  lastCompletionString = input
  lastCompletionSeed = seed
  result = await doCompletion(input, seed, 50)
defineAlias("complete", re"^nc\b")
defineAlias("complete", re"^\.nc\b")

defineIrcCommand(match, msg, user, channel, "completeContinue", "Continues the previous \"" & botname & " complete\""):
  var length = 150
  if msg != "":
    if isOP(user, channel):
      length = msg.parseInt()
    else:
      return "Only OPs can change the length of the output"
  length = min(length, 500) # a practical limit
  result = await doCompletion(lastCompletionString, lastCompletionSeed, length)
defineAlias("completeContinue", re"^ncc\b")
defineAlias("completeContinue", re"^\.ncc\b")

const
  emojiSimpleAlphabet = {
    "A": @["🇦"],
    "B": @["🇧"],
    "C": @["🇨"],
    "D": @["🇩"],
    "E": @["🇪"],
    "F": @["🇫"],
    "G": @["🇬"],
    "H": @["🇭"],
    "I": @["🇮"],
    "J": @["🇯"],
    "K": @["🇰"],
    "L": @["🇱"],
    "M": @["🇲"],
    "N": @["🇳"],
    "O": @["🇴"],
    "P": @["🇵"],
    "Q": @["🇶"],
    "R": @["🇷"],
    "S": @["🇸"],
    "T": @["🇹"],
    "U": @["🇺"],
    "V": @["🇻"],
    "W": @["🇼"],
    "X": @["🇽"],
    "Y": @["🇾"],
    "Z": @["🇿"],
    "!": @["❗️"],
    "?": @["❓"],
    "#": @["#️⃣"],
    "*": @["*️⃣"],
    "+": @["➕"],
    "0": @["0️⃣"],
    "1": @["1️⃣"],
    "2": @["2️⃣"],
    "3": @["3️⃣"],
    "4": @["4️⃣"],
    "5": @["5️⃣"],
    "6": @["6️⃣"],
    "7": @["7️⃣"],
    "8": @["8️⃣"],
    "9": @["9️⃣"],
  }.toTable
  emojiExtendedAlphabet = {
    "A": @["🇦","🅰️"],
    "B": @["🇧"],
    "C": @["🇨","©️","☪️"],
    "D": @["🇩","↩️"],
    "E": @["🇪","📧"],
    "F": @["🇫"],
    "G": @["🇬","⛽️"],
    "H": @["🇭","♓️"],
    "I": @["🇮","ℹ️"],
    "J": @["🇯","☔"],
    "K": @["🇰"],
    "L": @["🇱","🕒"],
    "M": @["🇲","Ⓜ️","♏️","♍️","〽"],
    "N": @["🇳","📈"],
    "O": @["🇴","🅾️","⭕️"],
    "P": @["🇵","🅿️"],
    "Q": @["🇶"],
    "R": @["🇷","®️"],
    "S": @["🇸", "💰","⚡️"],
    "T": @["🇹","✝️"],
    "U": @["🇺","⛎"],
    "V": @["🇻","♈️"],
    "W": @["🇼","〰️"],
    "X": @["🇽","❎","❌","✖️"],
    "Y": @["🇾","🌱"],
    "Z": @["🇿","💤"],
    "!": @["❗️","❕"],
    "?": @["❓","❔"],
    "#": @["#️⃣"],
    "*": @["*️⃣"],
    "+": @["➕"],
    "0": @["0️⃣"],
    "1": @["1️⃣"],
    "2": @["2️⃣"],
    "3": @["3️⃣"],
    "4": @["4️⃣"],
    "5": @["5️⃣"],
    "6": @["6️⃣"],
    "7": @["7️⃣"],
    "8": @["8️⃣"],
    "9": @["9️⃣"],
  }.toTable
proc emojify(input: string; extendedAlphabet: bool): string =
  let alphabet = if extendedAlphabet: emojiExtendedAlphabet else: emojiSimpleAlphabet
  let seed = hash(input)
  var idx = 0
  for s in input.utf8:
    let symb = s.toUpper
    if symb in alphabet:
      let emojiList = alphabet[symb]
      result &= emojiList[(idx + seed) mod emojiList.len]
      result &= ' ' # keep emojis from combining
      inc idx
    else:
      result &= symb
defineIrcCommand(match, msg, user, channel, "extraEmoji", "Turns text into it's emoji counterpart. Now with even more emoji! 🤪 'abc' -> '🅰️ 🇧 ☪️'"):
  result = emojify(getCmdParam(match, msg), true)
defineAlias("extraEmoji", re"(?i)^\.extraEmoji\b(?-i)")
defineAlias("extraEmoji", re"(?i)^\.eEmoji\b(?-i)")
defineAlias("extraEmoji", re"^\.ee\b")
defineIrcCommand(match, msg, user, channel, "emoji", "Turns text into it's emoji counterpart 'abc' -> '🇦 🇧 🇨'"):
  result = emojify(getCmdParam(match, msg), false)
defineAlias("emoji", re"(?i)^\.emoji\b(?-i)")
defineAlias("emoji", re"^\.e\b")

const words = staticRead("/usr/share/dict/words")
var wordList = words.split
defineIrcCommand(match, msg, user, channel, "godSays", "Outputs words from 'God' using RNG"):
  for i in countup(1, 10):
    result &= sample(wordList) & ' '
defineAlias("godSays", re"^\.g\b")
defineAlias("godSays", re"^\.gw\b")
defineAlias("godSays", re"^\.gs\b")
defineAlias("godSays", re"^\.god\b")
defineAlias("godSays", re"(?i)^\.godSays\b(?-i)")

defineIrcCommand(match, msg, user, channel, "play", re"^\.play http[s]?://(?:[a-zA-Z]|[0-9]|[$-_@.&+]|[!*\(\),]|(?:%[0-9a-fA-F][0-9a-fA-F]))+", "Adds a song to TSWF's queue", hiddenCmd = false):
  let tswfHttpClient = newAsyncHttpClient()
  var url = match
  url.removePrefix(".play ")
  let response = await tswfHttpClient.request(tswfApi & "/submit?song=" & url, HttpGet)
  var succeeded = false
  for key, node in parseJson(await response.body):
    if key == "Added":
      succeeded = true
  tswfHttpClient.close()
  if succeeded:
    result = "Added to queue"
  else:
    result = "Failed to add to queue"

defineIrcCommand(match, msg, user, channel, "current", re"^\.current$", "Returns the song that is currently being played by TSWF.", hiddenCmd = false):
  let tswfHttpClient = newAsyncHttpClient()
  let response = await tswfHttpClient.request(tswfApi & "/current", HttpGet)
  var succeeded = false
  var duration = ""
  var title = ""
  var url = ""
  for key, node in parseJson(await response.body):
    if key == "url":
      succeeded = true
      url = node.str
    elif key == "title":
      succeeded = true
      title = node.str
    elif key == "duration":
      succeeded = true
      duration = node.str
  tswfHttpClient.close()
  if succeeded:
    if title != "":
      result &= "\"" & title & "\" "
    if duration != "":
      result &= "[" & duration & "] "
    if url != "":
      result &= url
  else:
    result = "Failed to get current song"

defineIrcCommand(match, msg, user, channel, "skip", re"^\.skip$", "Votes to skip the current song being played by TSWF.", hiddenCmd = false):
  let tswfHttpClient = newAsyncHttpClient()
  let response = await tswfHttpClient.request(tswfApi & "/skip?username=" & user, HttpGet)
  var succeeded = false
  for key, node in parseJson(await response.body):
    if key == "Skip":
      succeeded = true
  tswfHttpClient.close()
  if succeeded:
    result = "Voted"
  else:
    result = "You voted already. 🔪"

defineIrcCommand(match, msg, user, channel, "queue", re"^\.queue$", "Outputs the first items of the TSWF queue and the total length of the queue.", hiddenCmd = false):
  const maxOutputLength = 3 # outs only this many items that are present in the TSWF queue
  let tswfHttpClient = newAsyncHttpClient()
  let response = await tswfHttpClient.request(tswfApi & "/queue", HttpGet)
  var succeeded = false
  var urls = newSeq[string]()
  for item in parseJson(await response.body):
    succeeded = true
    urls.add(item.str)
  tswfHttpClient.close()
  let totalQueueLength = urls.len
  while urls.len > maxOutputLength:
    urls.delete(0)
  if urls.len > 0:
    urls.reverse(urls.low, urls.high)
    for i, url in urls:
      result &= url
      if i != urls.high:
        result &= " , "
    if totalQueueLength > urls.len:
      result &= " , ..."
    if urls.len == 1:
      result = "1 item in queue: [ " & result & " ]"
    else:
      result = $totalQueueLength & " items in queue: [ " & result & " ]"
  else:
    result = "Nothing in the queue"

defineIrcCommand(match, msg, user, channel, "listeners", re"^\.listeners$", "Returns how many TSWF listeners there are.", hiddenCmd = false):
  const tries = 10; # because of an internal load balancer, the value reported by nginx isn't always right
  var largestCount = 0;
  for i in 1..tries:
    let tswfHttpClient = newAsyncHttpClient()
    let response = await tswfHttpClient.request(tswfApi & "/clients", HttpGet)
    let node = parseJson(await response.body)
    let count = node.num
    largestCount = max(largestCount, (int)count);
    tswfHttpClient.close()
    await sleepAsync(200)
  if largestCount == 0:
    result = "No clients listening."
  elif largestCount == 1:
    result = "One client listening."
  else:
    result = $largestCount & " clients listening."

defineIrcCommand(match, msg, user, channel, "image", re"\bhttps?:\/\/(?:[a-z0-9\-]+\.)+[a-z]{2,6}(?:\/[^\/#?]+)+\.(?:jpg|jpeg|gif|png)\b", "Uses YOLO to detect objects in images", hiddenCmd = true):
  let yoloHttpClient = newAsyncHttpClient()
  yoloHttpClient.headers = newHttpHeaders({ "Content-Type": "application/json" })
  let body = %*{ "url": msg }
  let response = await yoloHttpClient.request(objectDetectionApi, HttpPost, $body)

  var data = initTable[string,int]()
  for key, node in parseJson(await response.body):
    var count = 0
    for confidence in node.getElems():
      if confidence.getFloat() > 0.5:
        inc count
    data[key] = count
  yoloHttpClient.close()
  if data.len > 0:
    result = "Found objects: "
    var i = 0
    for key, count in data:
      result &= $count & ' '
      if count > 1:
        result &= key & 's'
      else:
        result &= key
      if i+1 < data.len:
        result &= ", "
      inc i

defineIrcCommand(match, msg, user, channel, "disable", "Disables a particular command"):
  if msg == "enable" or msg == "disable":
    return "( •̀ω•́ )σ"
  if not isOP(user, channel):
    return "Only OPs may use this command."
  if not cmdsByName.hasKey(msg):
    return "No such command: " & msg
  getCmdRestrictions(msg, channel).disabled = true
  result = "Ok"

defineIrcCommand(match, msg, user, channel, "enable", "Enables a particular command"):
  if msg == "enable" or msg == "disable":
    return "( •̀ω•́ )σ"
  if not isOP(user, channel):
    return "Only OPs may use this command."
  if not cmdsByName.hasKey(msg):
    return "No such command: " & msg
  getCmdRestrictions(msg, channel).disabled = false
  result = "Ok"

defineIrcCommand(match, msg, user, channel, "allowOPs", "Allows only OPs to use a particular command"):
  if msg == "allowOPs" or msg == "allowEveryone":
    return "" # nothing to do
  if not isOP(user, channel):
    return "Only OPs may use this command."
  if not cmdsByName.hasKey(msg):
    return "No such command: " & msg
  getCmdRestrictions(msg, channel).opOnly = true
  result = "Ok"

defineIrcCommand(match, msg, user, channel, "allowEveryone", "Allows everyone to use a particular command"):
  if msg == "allowOPs" or msg == "allowEveryone":
    return "( •̀ω•́ )σ"
  if not isOP(user, channel):
    return "Only OPs may use this command."
  if not cmdsByName.hasKey(msg):
    return "No such command: " & msg
  getCmdRestrictions(msg, channel).opOnly = false
  result = "Ok"

defineIrcCommand(match, msg, user, channel, "leave", "Tells " & botname & " to leave the channel"):
  if not isOP(user, channel):
    return "Only OPs may use this command."
  await client.part(channel, "redrum")

defineIrcCommand(match, msg, user, channel, "join", "Tells " & botname & " to join a channel"):
  let newChannel = msg
  if not newChannel.startsWith("#"):
    return "That's not a channel"
  #await client.send("NAMES " & newChannel)
  #await sleepAsync(2000) # sleep for two seconds while the irc server sends names + OPs of the server
  await client.send("WHOIS " & user)
  if isOP(user, newChannel):
    await client.join(newChannel)
  else:
    return "You must be an OP of the server " & botname & " would join."

defineIrcCommand(match, msg, user, channel, "bots", re"^\.bots$", "", hiddenCmd = true):
  result = botname & " checking in. For help, run \"" & botname & " help\"."

defineIrcCommand(match, msg, user, channel, "default", re("(?i)^" & botname & "(?-i)"), "", hiddenCmd = true):
  result = "No such command (Try \"" & botname & " help\")"

# go desu
# go help
# go {OwO,UwU,qt)
# go get
# go fuck yourself
# go kys
# go protip
#   [Motivation]
#   ffmpeg -help full
# gopher
# go 8ball
# opencv YOLO object detection

# bash expressions (!!)
# echo
# emoji text replace
# video/audio streams?
# best (OS, pony, waifu, etc.)
# rms (is this done already?)
# pastebin-like service if output is too long
# drawr?
# libgen api search
# commands to promote/make fun of nim
# manpage system
# expression evaluator
# alexa commands (maybe natural language processing too?)
# auto archiver/fetcher

# ancap quotes whenever someone mentions communism
# read the script reminder when someone whines
# god says (TempleOS)

proc addToHistory(msg: string) =
  if history.len >= historySize:
    history.popLast()
  history.addFirst(msg)

proc sendEntireMessage(client: AsyncIrc; nick, msg: string) {.async.} =
  if msg == "":
    return
  var workingStr = ""
  for word in msg.split(re"\s+"):
    if workingStr.len + word.len + 1 <= maxMsgLen:
      workingStr &= word & ' '
    else:
      workingStr = workingStr.strip
      await client.privmsg(nick, workingStr)
      addToHistory(workingStr)
      await sleepAsync(msgSleep)
      workingStr = word
  if workingStr != "":
    workingStr = workingStr.strip
    await client.privmsg(nick, workingStr)
    addToHistory(workingStr)

proc ircCallback(client: AsyncIrc, ev: IrcEvent) {.async.} =
  try:
    case ev.typ
    of EvConnected:
      echo "connected"
    of EvDisconnected:
      echo "disconnected"
    of EvTimeout:
      echo "timeout"
    of EvMsg:
      let cmd = ev.raw.split[1]
      let channel = ev.params[0]
      if cmd == "JOIN" or cmd == "PART" or cmd == "NICK":
        await client.send("NAMES " & channel)
      echo ev.raw
      if cmd == "PRIVMSG":
        let isChannel = channel != botname
        let nick = ev.raw.split('!')[0].split(':')[1]
        let msg = ev.params[1]
        var rtn = ""
        for key, match in regex.findCommandMatches(msg):
          let ircCmd = cmdsByName[key]
          let cmdParameter = if ircCmd.isCustomRegex: msg else: msg.replace(match, "").strip
          rtn = await runCmdIfAllowed(key, match, cmdParameter, nick, channel)
          if rtn != "":
            break
        addToHistory(msg)
        if rtn != "":
          let msgs = rtn.split('\n')
          let destination = if isChannel: channel else: nick
          for msg in msgs:
            await sendEntireMessage(client, destination, msg)
            await sleepAsync(msgSleep)
  except:
    echo "Get exception ", repr(getCurrentException()), " with message ", getCurrentExceptionMsg()

when isMainModule:
  history.addFirst("")
  regex = buildPrimaryRegex(cmds)

  client = newAsyncIrc(
    address = ircServerAddress,
    port = Port(ircServerPort),
    nick = botname,
    user = botname,
    realname = botname,
    serverPass = ircPassword,
    joinChans = ircChannels,
    msgLimit = false,
    callback = ircCallback)
    
  waitFor client.run()
