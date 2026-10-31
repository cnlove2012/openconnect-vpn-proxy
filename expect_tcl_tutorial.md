# Expect 与 Tcl 从入门到实战

**适合读者：** 熟悉 Shell、PHP 或 Python，但第一次接触 Tcl / Expect 的开发者。

**学习目标：** 能读懂 `.exp` 文件，理解它为什么不是 Shell；掌握 Tcl 基础语法和 Expect 的交互模型；能维护一个"自动输入密码、人工输入验证码、持续运行 OpenConnect"的脚本。

> 示例中的账号、密码、验证码、内网地址均为占位内容。不要把真实凭据写进教程、代码仓库或日志。教程里的代码我大多在 Tcl 8.6 + Expect 5.45 上实际跑过，涉及真实服务器的部分用模拟程序测试，没有连真实设备。

---

## 怎么读这份教程

| 你的目标 | 建议路线 | 大约时间 |
|---|---|---|
| **快速读懂 `openconnect.exp`** | 前言 → 第 0 节 → 1.1–1.5、1.7 → 2.1–2.7.1，再对照仓库里的 `docker/openconnect.exp` | 1 小时 |
| **能自己写简单的 Expect 脚本** | 在上面基础上，再读完第一部分、第二部分（含 2.14「动手」），做练习 1–6 | 半天 |
| **深入掌握、能排查问题** | 通读全部，重点看 1.5.1（替换时机）、第三部分（陷阱），做完全部练习 | 2–3 天，每天 30–45 分钟 |
| **只想查某个命令** | 直接翻附录 A（速查表）和附录 B（官方资料） | 随时 |

### 目录

- **前言**：Tcl 是什么，能干什么；什么情况下应该使用 Expect
- **第 0 节**：Tcl、Expect、`.exp` 三者关系，怎么运行
- **第一部分：Tcl 基础**（1.1 – 1.12）
- **第二部分：Expect**（2.1 – 2.14）
- **第三部分：常见陷阱**
- **第四部分：示例应用**
- **第五部分：练习**
- **第六部分：延伸**（含 Expect、Shell、Python、Ansible 怎么选）
- **附录 A：速查表**　**附录 B：官方资料**　**结语**

---

## 前言：Tcl 是什么，能干什么

### Tcl 简介

**Tcl**（读作 "tickle"，全称 Tool Command Language）是一门解释型脚本语言，1988 年由 John Ousterhout 在加州大学伯克利分校设计。设计初衷是做一个**可以嵌入到其他程序里的"命令语言"**：C 程序把核心功能做成一组命令，再嵌入 Tcl 解释器，用户就能用脚本自由组合这些命令，而不用重新编译程序。

它的特点：

- **语法极简**：核心只有十几条规则，"一行 = 命令 + 参数"（见 1.1 节）。
- **一切皆字符串**：数字、列表、代码块本质上都是字符串，所以很容易动态生成并执行代码。
- **易嵌入、易扩展**：解释器很小，用 C 写扩展非常方便，Expect 和 Tk 都是这样来的。
- **跨平台**：Linux、macOS、Windows 都能用，几乎不需要改脚本。
- **自带事件循环和 socket**：写小型网络工具、定时任务很方便。

### 它的两个著名"孩子"

| 扩展 | 作者与时间 | 用途 |
|---|---|---|
| **Tk** | Ousterhout，1991 | 图形界面工具包。Python 的 tkinter 就是它的绑定 |
| **Expect** | Don Libes（NIST），1990 | 自动化交互式程序，也就是本教程的主角 |

### Tcl 实际用在哪里

Tcl 现在不是热门通用语言，但在下面这些领域很常见，所以你可能在不知不觉中已经碰到过它：

| 领域 | 例子 |
|---|---|
| **芯片设计 / EDA** | Synopsys、Cadence 的工具，以及 Xilinx/AMD Vivado，脚本语言都是 Tcl，约束文件和综合流程大量使用 |
| **网络设备** | Cisco IOS 内置 `tclsh`，可以在设备上直接跑 Tcl 脚本；F5 BIG-IP 的 iRules 也是 Tcl 方言 |
| **自动化测试** | SQLite、Redis 的测试套件都是用 Tcl 写的；Expect 常用来测试命令行程序 |
| **嵌入式 / 调试** | OpenOCD 的配置和命令行就是 Tcl |
| **仿真与科研** | ns-2 网络仿真器的场景脚本（用的是 Tcl 的面向对象扩展 OTcl） |
| **运维自动化** | 用 Expect 批量登录设备、自动应答安装程序、自动化交互式工具 |

**一句话总结**：Tcl 擅长"把一堆命令胶合起来、驱动别的程序"，而 Expect 把这个能力延伸到了"驱动需要人敲键盘的程序"。

### Tcl 这门语言：什么时候该用、什么时候不该用

| 适合 | 不太适合 |
|---|---|
| 自动化交互式命令行（ssh、telnet、串口、设备 CLI） | 复杂业务系统、Web 后端 |
| 维护已有的 EDA / 网络设备 Tcl 脚本 | 需要丰富第三方库的数据处理（用 Python 更方便） |
| 写一次性的小工具，要求依赖少 | 团队里没人熟悉 Tcl 的长期项目 |

---

## 前言二：什么情况下应该使用 Expect

上面讲的是 Tcl 这门语言。具体到 Expect，判断标准要更明确一些。

### Expect 最适合的场景

Expect 的典型使用条件是：**你要控制的程序没有合适的非交互接口，只能通过终端提示用户输入。**

| 场景 | 示例 | Expect 能做什么 |
|---|---|---|
| SSH 交互登录 | 旧设备只能密码登录，首次连接要求确认主机指纹 | 等待密码提示并输入，处理首次确认 |
| 网络设备维护 | 路由器、交换机、串口控制台 | 等待命令提示符，再发送配置命令 |
| VPN 客户端 | OpenConnect、旧版 VPN CLI | 自动输入密码，保留 OTP 人工输入 |
| 交互式安装器 | 安装程序不断询问路径、协议、是否继续 | 按提示选择选项 |
| 数据库命令行 | 某些只支持交互登录的管理工具 | 处理登录提示和交互命令 |
| 自动化测试 | 命令行程序要求输入确认、口令或选择项 | 模拟用户操作，检查输出结果 |
| 串口和终端设备 | 设备启动后显示登录提示 | 发送登录信息和控制命令 |

### 一个判断标准：先问三个问题

1. 我要控制的程序，是否提供 API、配置文件、stdin、环境变量或非交互参数？
2. 它是否必须在终端里输出提示，再等待用户输入？
3. 这种交互是否稳定、可识别，能通过文本提示或正则判断？

如果第 1 个问题的答案是"有成熟的非交互接口"，**优先用那个接口**。如果程序只能通过终端交互，且提示文本相对稳定，Expect 就很合适。一个实用原则：**先找程序提供的正式接口；没有合适接口，再考虑 Expect。**

### 哪些情况不应该使用 Expect

- **有正式 API 的系统**：优先用 HTTP API、SDK，或命令行的 JSON 输出模式。
- **常规批处理**：工具支持 `--password-file`、stdin、配置文件或环境变量时，优先用这些接口。
- **复杂业务逻辑**：大量数据处理、并发、重试策略、结构化日志，更适合 Python、Go 等语言。
- **网页自动化**：Expect 控制的是终端进程，不是浏览器页面，网页自动化应使用 Playwright 等工具。
- **不稳定的文本界面**：提示文本会随语言、版本、终端宽度不断变化时，脚本容易失效。
- **高敏感凭据**：不应为了方便，把员工个人密码、MFA 秘钥长期写进脚本或镜像。

### Expect 的边界

Expect 控制的是"终端交互"，它不理解被控程序内部的业务语义，也不会自动知道登录是否真的成功。以 OpenConnect 为例：

- Expect 能看到 `Password:` 并输入密码；
- Expect 能看到 `Please input SMS Code:` 并转交验证码；
- 但认证是否真的成功，要看 OpenConnect 是否建立了隧道、是否拿到 VPN 地址、路由是否正确。

所以 Expect 解决的是**交互自动化**，不是 VPN 协议本身。出了问题要分层定位：服务端认证问题、OpenConnect 参数问题、Expect 输入问题、Docker 网络问题，彼此是独立的。

---

## 0. 先搞清楚三者关系

| 名称 | 是什么 |
|---|---|
| **Tcl** | 一门脚本语言（Tool Command Language），Expect 的"母语" |
| **Expect** | Tcl 的扩展库，专门用来自动化交互式程序 |
| `expect` 命令行程序 | 一个带 Expect 扩展的 Tcl 解释器，用来运行 `.exp` 脚本 |

所以 `.exp` 文件 = Tcl 语法 + 几条 Expect 专用命令。学习顺序：先 Tcl 基础，再 Expect 命令。

### `.exp` 文件是什么

`.exp` 只是 Expect 脚本常见的扩展名，没有特殊魔法。真正决定由谁来解释的，是文件**第一行**：

```tcl
#!/usr/bin/expect -f
```

它表示用 `/usr/bin/expect` 来解释这个文件，`-f` 表示从文件读取命令。

### 运行方式

```bash
expect -f script.exp                  # 方式一：显式调用 expect 解释器
chmod +x script.exp && ./script.exp   # 方式二：给执行权限后直接运行
```

安装：`apt install expect`（Debian/Ubuntu），`brew install expect`（macOS）。

### 不要用 `tclsh` 运行 `.exp`

```bash
tclsh openconnect.exp      # 错误
```

`tclsh` 是普通的 Tcl 解释器，**没有加载 Expect 扩展**，所以一遇到 `spawn` 就会报：

```
invalid command name "spawn"
```

这是新手最常见的第一个报错。凡是用到 `spawn`、`expect`、`send` 的脚本，都要用 `expect` 运行。反过来，`expect` 也能运行不含 Expect 命令的纯 Tcl 脚本。

### 它们之间的关系

```text
openconnect.exp
    │  Tcl 语法：变量、if、foreach、list、proc、catch
    │  Expect 命令：spawn、expect、send、expect_user、wait
    ▼
Expect 解释器（/usr/bin/expect）
    │  创建并控制子进程（通过伪终端）
    ▼
OpenConnect 命令行程序
    ├── 输出 Password:           → Expect 自动发送密码
    ├── 输出 Please input SMS Code: → Expect 让人输入验证码
    ├── 输出 Login failed        → Expect 停止并报错
    └── 输出 Configured as ...   → Expect 保持进程运行
```

---

## 第一部分：Tcl 基础

### 1.1 核心思想：一切都是命令，一切都是字符串

Tcl 的语法只有一条规则：**一行 = 一个命令 + 若干参数，用空格分隔**。

```tcl
puts "hello"          ;# 命令 puts，参数 "hello"
set name "Tom"        ;# 命令 set，参数 name 和 "Tom"
```

没有关键字，`if`、`while`、`proc` 全是普通命令，只是它们的参数里带着"代码块"。这是它和其他语言最不同的地方，也是下面"花括号必须这样写"的原因。

注释以 `#` 开头，且必须出现在**命令开头**。行尾注释要先用 `;` 结束上一个命令：

```tcl
# 整行注释
set x 1 ;# 行尾注释
```

Tcl 不要求语句以分号结尾，**换行就结束一条命令**；分号用来在同一行写多条命令：

```tcl
set a 10; set b 20
puts [expr {$a + $b}]          ;# 30
```

对照 PHP：`$port = 8888; echo $port;` 在 Tcl 里是 `set port 8888; puts $port`。区别在于 Tcl 的"赋值"和"取值"是两种不同写法：`set` 是命令，`$port` 是变量替换。

### 1.2 变量：`set` 与 `$`

```tcl
set name "Tom"        ;# 赋值，注意没有 =
puts $name            ;# 读取，用 $
puts "Hi, $name"      ;# 双引号里可以替换
puts {Hi, $name}      ;# 花括号里不替换，原样输出：Hi, $name
```

### 1.3 三种引号/括号（最重要的一节）

| 写法 | 含义 |
|---|---|
| `"..."` | **允许替换**：`$变量`、`[命令]`、`\n` 都会被处理 |
| `{...}` | **不做任何替换**，原样保留，常用来包代码块和正则 |
| `[...]` | **命令替换**：先执行里面的命令，用结果替换，类似 shell 的 `$(...)` |

```tcl
set a 3
set b [expr {$a + 2}]          ;# b = 5
puts "a=$a, b=$b"              ;# a=3, b=5
puts {a=$a}                    ;# a=$a
```

### 1.4 数学运算：`expr`

```tcl
set x [expr {1 + 2 * 3}]       ;# 7
if {$x > 5} { puts "big" }
```

**规则：`expr` 的表达式永远用花括号包起来。** 不加花括号能跑，但慢且有安全隐患。

### 1.5 条件、循环

```tcl
if {$x > 10} {
    puts "gt 10"
} elseif {$x > 5} {
    puts "gt 5"
} else {
    puts "small"
}
```

**踩坑**：`}` 和 `else` 必须写在同一行，否则 Tcl 会认为 `if` 命令已经结束。

字符串比较用 `eq` / `ne`，数字比较用 `==` / `!=`：

```tcl
if {$name eq "Tom"} { ... }
if {$vpn_group ne ""} { ... }
```

循环：

```tcl
foreach item {a b c} { puts $item }

set i 0
while {$i < 3} {
    puts $i
    incr i                      ;# i++
}

for {set i 0} {$i < 3} {incr i} { puts $i }
```

### 1.5.1 替换到底发生在什么时候？（理解 Tcl 的关键）

这一节回答两个常见疑问：

- `if {[info exists env(X)]} { ... }` 里的 `[...]`，是先执行再交给 `if`，还是整个交给 `if` 去执行？
- 为什么条件一定要写花括号？

#### 规则：Tcl 解析一行命令时，从左到右分两步

1. **解析阶段**：把这一行切成"命令名 + 参数"。切的同时，对没被保护的参数做替换：`$变量` 换成值，`[命令]` 先执行并换成结果。
2. **执行阶段**：把替换后的参数交给命令。

**花括号 `{...}` 的作用就是：在第 1 步里整段原样保留，不做任何替换。** 替换不会消失，只是推迟到接收这段文本的命令内部，由它自己决定何时、是否求值。

#### 回答第一个问题

```tcl
if {[info exists env(VPN_AUTHGROUP)]} { puts "has group" }
```

- 解析阶段：条件被花括号包住，`if` 收到的第一个参数是纯文本 `[info exists env(VPN_AUTHGROUP)]`，**此时 `[...]` 还没有执行**。
- 执行阶段：`if` 把这段文本当作 `expr` 表达式求值。`expr` 在求值过程中遇到 `[...]`，这时才执行 `info exists ...`，得到 `0` 或 `1`，再判断真假。

所以答案是：**整个 `[...]` 先原样交给 `if`，由 `if` 在求值时去执行它。**

#### 对照：同一个命令，有无花括号

```tcl
if {[info exists env(X)]} { puts yes }   ;# 条件是文本，由 if 自己求值
if [info exists env(X)]   { puts yes }   ;# 解析阶段先执行 [..]，if 收到的是 0 或 1
```

这个例子里两种写法结果相同，因为条件只需要求值一次。区别出现在**条件需要反复求值**的场合：

```tcl
set i 0

while {$i < 3} { incr i }     ;# 正确：条件是文本，每轮循环 while 都重新求值
                              ;# 第 1 轮 0<3，第 2 轮 1<3，第 3 轮 2<3，第 4 轮 3<3 假，结束

while "$i < 3" { incr i }     ;# 错误：双引号在解析阶段就把 $i 换成 0，while 收到的条件是固定文本 "0 < 3"
                              ;# 永远为真，死循环
```

如果连引号也不加，直接写 `while $i < 3 { incr i }`，参数个数对不上，Tcl 会直接报 `wrong # args: should be "while test command"`。所以条件里有空格时，要么用花括号，要么用引号，但引号会引入上面的"提前替换"问题，**所以花括号才是正确写法**。

#### 逐步还原一次解析

以 `set b [expr {$a + 2}]`（假设 `a` 是 3）为例：

| 步骤 | 发生了什么 |
|---|---|
| 1 | `set` 的第二个参数是 `[expr {$a + 2}]`，解析器要先执行方括号里的命令 |
| 2 | 执行 `expr {$a + 2}`：花括号保护 `$a + 2`，`expr` 收到文本 `$a + 2` |
| 3 | `expr` 自己把 `$a` 换成 3，算出 5 |
| 4 | 方括号被替换为 5，`set` 收到 `b` 和 `5`，赋值 |

这里有两层：外层 `[...]` 由解析器执行；内层 `{...}` 里的 `$a` 由 `expr` 自己替换。

#### 一张表记住

| 写法 | 谁来做替换 | 何时做 |
|---|---|---|
| `"..."` 或不加引号 | Tcl 解析器 | 命令被调用**之前**，只做一次 |
| `{...}` | 接收它的命令（`if`、`while`、`expr`、`proc` 等） | 命令**内部**，可以多次 |

#### 实用口诀

- 给 `if` / `while` / `for` 的**条件**，一律加花括号。
- 给 `expr` 的**表达式**，一律加花括号。
- 给 `if` / `while` / `foreach` / `proc` / `expect` 的**代码块**，天然就是花括号。
- 想要"现在立刻拿到命令结果赋给变量"，用方括号，且不放在花括号里：`set b [expr {...}]`。

这也是 1.1 说的"代码块作为参数"：`if` 之类的命令并不是语法关键字，它们只是接收一段文本、再自行决定如何执行的普通命令。

### 1.6 列表（list）

```tcl
set cmd [list openconnect --protocol=anyconnect --no-dtls]
lappend cmd "--authgroup=duanxin"      ;# 追加
puts [llength $cmd]                    ;# 4
puts [lindex $cmd 0]                   ;# openconnect
foreach arg $cmd { puts $arg }
```

**一个元素里含空格怎么办？** 用 `list` 命令或引号包住，它会当作一个整体：

```tcl
set cmd [list openconnect "--useragent=AnyConnect Linux_64 5.1.2.42"]
llength $cmd                           ;# 2，不是 5
```

`{*}$cmd`（展开）把列表拆成多个独立参数，类似 shell 的 `"${arr[@]}"`：

```tcl
spawn -noecho {*}$cmd
```

### 1.7 数组（关联数组）与环境变量

```tcl
set user(name) "Tom"
set user(age) 20
puts $user(name)
puts [array names user]                ;# 列出所有键：name 和 age（顺序不保证，可能是 age name）
```

数组的常用操作：

```tcl
array set count {}                     ;# 创建一个空数组（只是声明它存在）
array set user {name Tom age 20}       ;# 一次设置多个元素：键 值 键 值 ...
set count(ERROR) 0                     ;# 也可以逐个设置

if {[info exists count(ERROR)]} { ... }   ;# 判断某个元素是否存在
puts [array exists count]              ;# 判断 count 是不是数组，1 或 0
puts [array size user]                 ;# 元素个数：2
puts [array get user]                  ;# 转成"键 值 键 值"的列表，如 age 20 name Tom（顺序不保证）
incr count(ERROR)                      ;# 元素也能自增，每次加 1
unset count(ERROR)                     ;# 删除一个元素
```

关于 `incr` 一个**还不存在**的元素：Tcl 8.5 及以上会自动把它当作 0 再加 1，老版本则会报错。示例 1 里先用 `info exists` 判断再初始化，是为了在老版本上也能跑；你的环境是 Tcl 8.6，不写这个判断也可以。

### 1.7.1 字典（dict）

数组不能整体当作一个值传给过程或赋给别的变量，字典可以。字典本质上是一个"键 值 键 值 ..."形式的列表，所以更适合当作数据来回传递。

```tcl
set cfg [dict create host 127.0.0.1 port 8888]   ;# 创建
dict set cfg timeout 30                          ;# 新增或修改一个键：dict set 字典变量名 键 值
puts [dict get $cfg port]                        ;# 取值：8888
puts [dict exists $cfg host]                     ;# 键是否存在：1
puts [dict keys $cfg]                            ;# host port timeout
dict unset cfg timeout                           ;# 删除一个键

dict for {k v} $cfg {                            ;# 遍历：每轮把键放进 k，值放进 v
    puts "$k = $v"
}
```

和数组的两点区别：

- `dict set` 的第一个参数是**变量名**（不带 `$`），它会直接修改这个变量；`dict get` 的第一个参数是**值**（带 `$`）。
- 字典是一个值，可以直接传给 `proc`、放进列表；数组做不到这点。

选哪个？只在当前脚本里零散存几个值、按键读写，用数组就够；要整体传递或嵌套，用字典。

环境变量就是名为 `env` 的数组：

```tcl
puts $env(HOME)
if {[info exists env(VPN_AUTHGROUP)]} { puts "has group" }
unset env(VPN_PASSWORD)                ;# 删除，子进程将看不到
```

### 1.8 字符串操作

```tcl
string length "abc"                    ;# 3
string trim "  abc  "                  ;# abc
string toupper "abc"                   ;# ABC
string match "*.exp" "a.exp"           ;# 1（通配符匹配）
string range "abcdef" 1 3              ;# bcd
string map {a 1 b 2} "aabbc"           ;# 1122c

# 正则：regexp 模式 字符串 整体匹配变量 分组1变量 ...
if {[regexp {(\d+)\.(\d+)} "v9.12" all major minor]} {
    puts "$major / $minor"             ;# 9 / 12
}
```

`regexp` 的返回值是 1（匹配）或 0（不匹配），所以可以直接放在 `if` 里。比如检查验证码是不是 6 位数字：

```tcl
set otp [string trim "123456 "]
if {[regexp {^[0-9]{6}$} $otp]} {
    puts "valid OTP format"
}
```

`regexp` 只能检查**格式**，不代表验证码在服务端一定有效。后面的变量依次接收"整体匹配"和"各括号分组"。如果你不关心整体匹配，可以随便起个占位名，惯例是写 `->`：

```tcl
regexp {(\d+)\.(\d+)} "v9.12" -> major minor   ;# -> 只是一个变量名，用来接收整体匹配
```

**列表排序**也放在这里：

```tcl
puts [lsort {banana apple cherry}]     ;# apple banana cherry
puts [lsort -integer {10 9 100}]       ;# 9 10 100
puts [lsort -decreasing {a c b}]       ;# c b a
```

### 1.9 过程（函数）

```tcl
proc greet {name {greeting "Hello"}} {     ;# 第二个参数有默认值
    return "$greeting, $name"
}
puts [greet "Tom"]                         ;# Hello, Tom
puts [greet "Tom" "Hi"]                    ;# Hi, Tom
```

**变量作用域**：`proc` 里默认看不到外面的变量，要 `global` 声明：

```tcl
set counter 0
proc bump {} {
    global counter
    incr counter
}
```

### 1.10 错误处理：`catch`

```tcl
if {[catch {exec ls /nonexistent} err]} {
    puts "failed: $err"
}
```

`catch {代码} 变量` 返回 0 表示成功，非 0 表示出错，错误信息放进变量。Expect 脚本里大量用 `catch {close}; catch {wait}` 来"尽力清理但别因此崩溃"。

`catch` 也可以包住一个返回值的命令，成功时变量里是返回值，失败时是错误信息：

```tcl
if {[catch {open "/tmp/demo.txt" r} file]} {
    puts stderr "open failed: $file"          ;# 失败：file 里是错误信息
} else {
    close $file                               ;# 成功：file 里是文件句柄
}

set rc [catch { error "boom" } error_message]
puts "rc=$rc msg=$error_message"              ;# rc=1 msg=boom
```

`catch` 不会修复错误，它只是让脚本有机会自己处理，而不是直接异常退出。

### 1.11 执行外部命令与文件

```tcl
set out [exec date]                    ;# 执行并取输出
exec kill -TERM $pid

set f [open "/tmp/a.txt" w]
puts $f "line"
close $f

set f [open "/tmp/a.txt" r]
set data [read $f]
close $f
```

### 1.11.1 逐行读文件：`gets`

```tcl
set f [open "app.log" r]
while {[gets $f line] >= 0} {          ;# gets 读一行放进 line，返回长度；读到文件尾返回 -1
    puts "got: $line"
}
close $f
```

`gets 通道 变量` 每次读一行，读到末尾返回 -1，所以用 `>= 0` 作为循环条件。这就是 `while` 逐行处理文件的标准写法（示例 1 就是这样）。

### 1.11.2 网络与事件循环：`socket`、`vwait`

下面是语法示意（中文是占位，不能直接运行，可运行的完整例子见示例 3）：

```tcl
socket -server 处理过程名 端口    ;# 监听端口，每来一个连接就调用处理过程
set s [socket host 9000]          ;# 作为客户端连接
fconfigure $chan -buffering line  ;# 设置通道属性，这里是"按行刷新输出"
vwait forever                     ;# 进入事件循环：阻塞等待，让上面注册的回调有机会运行
```

只要知道这几句就够读懂示例 3：`socket -server` 注册回调，`vwait forever` 让脚本别退出，持续处理新连接。

### 1.11.3 全局变量与 `::`

`::` 表示全局命名空间。在 `proc` 里读全局变量有两种写法：

```tcl
proc show {} {
    global counter                 ;# 方式一：先声明
    puts $counter
    puts $::counter                ;# 方式二：直接用 ::，等价
    puts $::env(HOME)              ;# 环境变量数组 env 也是全局的，所以要写 $::env(...)
}
```

在 `proc` 外面写 `$env(HOME)` 就可以，`proc` 里面要写 `$::env(HOME)`。示例 5 里就用到了这一点。

### 1.12 Tcl 速查：和 shell 的对照

| 需求 | shell | Tcl |
|---|---|---|
| 赋值 | `a=1` | `set a 1` |
| 取值 | `$a` | `$a` |
| 命令替换 | `$(cmd)` | `[cmd]` |
| 数学 | `$((1+2))` | `[expr {1+2}]` |
| 环境变量 | `$HOME` | `$env(HOME)` |
| 字符串相等 | `[ "$a" = "b" ]` | `{$a eq "b"}` |
| 数组展开 | `"${arr[@]}"` | `{*}$list` |
| 打印 | `echo` | `puts` |
| 退出 | `exit 1` | `exit 1` |

---

## 第二部分：Expect

### 2.1 工作模型

```
spawn 启动程序 ──► expect 等待输出匹配 ──► send 发送输入 ──► 再 expect ...
```

Expect 会为被控程序创建一个**伪终端（pty）**，程序以为自己连着真人键盘。这就是为什么 `echo 密码 | openconnect` 不稳定，而 Expect 稳定：很多程序（ssh、sudo、openconnect）会特意读取终端而不是标准输入。

可以把一个多分支的 `expect` 理解成**"等待事件的状态机"**：收到不同的输出，就执行不同的动作，再决定是继续等还是结束。整个 OpenConnect 脚本就是这样一台状态机：`Password:` → `SMS Code:` → `Configured as`。

### 2.1.1 命令一览

Expect 的命令可以按"启动、等待、输入、交接、回收"来记。先看全貌，后面逐个展开：

| 命令 | 用途 | 典型写法 |
|---|---|---|
| `spawn` | 启动被控子进程 | `spawn ssh user@host` |
| `expect` | 等待子进程输出并匹配 | `expect "Password:"` |
| `send` | **向子进程**发送输入 | `send -- "$pw\r"` |
| `send_user` | **向你的屏幕**输出 | `send_user "请输入验证码"` |
| `expect_user` | 等待**你的键盘**输入 | `expect_user -re {...}` |
| `exp_continue` | 处理完当前提示后继续等 | 多阶段认证 |
| `interact` | 把终端交给人 | 需要人接管时 |
| `exp_pid` | 取子进程 PID | `set pid [exp_pid]` |
| `wait` | 回收子进程、取退出状态 | `set result [wait]` |
| `close` | 关闭与子进程的通道 | 清理 |
| `exit` | 退出脚本 | `exit 1` |
| `trap` | 捕获信号 | 处理 SIGTERM |
| `log_user` | 控制子进程输出是否显示 | `log_user 1` |
| `stty` | 调整终端属性 | `stty -echo` |

记住方向：`send` / `expect` 面向**子进程**，`send_user` / `expect_user` 面向**你自己**。

### 2.2 最小例子

```tcl
#!/usr/bin/expect -f
spawn ssh user@host
expect "password:"
send "secret\r"
expect "$ "
send "ls\r"
expect "$ "
send "exit\r"
expect eof
```

注意：

- `send` 发送的是**按键**，回车要写 `\r`（不是 `\n`）。
- `expect eof` 等程序结束。

### 2.3 spawn

```tcl
spawn ssh user@host
spawn -noecho {*}$cmd                  ;# -noecho：不回显 spawn 那一行
set pid [exp_pid]                      ;# 取被控进程的 PID
```

`spawn` 成功后，后续的 `expect` / `send` 默认作用于这个进程（由变量 `spawn_id` 记录）。

### 2.4 expect：模式匹配

`expect` 有三种模式写法：

```tcl
expect "password:"                     ;# 默认：glob 通配符匹配，* ? [..] 有特殊含义
expect -ex "a*b"                       ;# -ex：精确字符串，* 不特殊
expect -re {(?i)password:\s*$}         ;# -re：正则
```

**多模式 + 动作**（最常用的形式）：

```tcl
expect {
    -re {(?i)password:}  { send "$pw\r"; exp_continue }
    "yes/no"             { send "yes\r";  exp_continue }
    timeout              { puts "timed out"; exit 1 }
    eof                  { puts "closed" }
}
```

特殊模式：

| 模式 | 触发条件 |
|---|---|
| `timeout` | 等待超过 `$timeout` 秒 |
| `eof` | 被控程序结束 |
| `default` | `timeout` 或 `eof` 都算 |

### 2.5 `exp_continue`：继续等

匹配到一个模式、执行完动作后，**默认 `expect` 就结束了**。加上 `exp_continue` 才会回到 `expect` 继续等下一个模式（并且**重置超时计时**）。

```tcl
expect {
    -re {Password:}  { send "$pw\r"; exp_continue }   ;# 发完密码继续等
    -re {Connected}  { puts "ok" }                    ;# 不加 exp_continue → 结束
}
```

### 2.6 超时

```tcl
set timeout 30                         ;# 等待匹配最多 30 秒
set timeout -1                         ;# 永不超时（你的脚本用的）
```

**不设置的话默认是 10 秒**（我在 Expect 5.45 上实测过 `$timeout` 的初始值）。

自动化登录一般设有限超时，避免永久卡死；但你的脚本里需要等人输入验证码，所以用 `-1`。

也可以**分阶段调整**：认证阶段用有限超时，连接成功后再改成永不超时去等进程长期运行：

```tcl
set timeout 120                        ;# 认证阶段：最多等 2 分钟
# ……执行登录交互……

set timeout -1                         ;# 检测到 VPN 成功后
expect eof                             ;# 一直等到 openconnect 退出
```

注意：`expect_user`（等人敲键盘）同样受当前 `timeout` 影响。要不要允许人"无限期"地慢慢输入验证码，需要明确决定。

### 2.7 捕获匹配内容：`expect_out`

```tcl
expect -re {Configured as ([0-9.]+)}
puts "IP is $expect_out(1,string)"     ;# 第 1 个括号分组
puts $expect_out(0,string)             ;# 整个匹配的文本
puts $expect_out(buffer)               ;# 到匹配为止的全部缓冲
```

### 2.7.1 与人交互：`send_user` / `expect_user`

`send` 是**发给被控程序**；`send_user` 是**打印到你自己的屏幕**。同理 `expect` 等被控程序，`expect_user` 等你自己敲键盘。

```tcl
send_user "请输入验证码: "
expect_user -re {([^\r\n]+)\r?\n}
set otp [string trim $expect_out(1,string)]
send -- "$otp\r"
```

`send --` 里的 `--` 表示后面不再是选项，防止内容以 `-` 开头被误当参数。

**验证码的格式检查。** 如果想只接受 6 位数字，**不要**把 `[0-9]{6}` 直接写进 `expect_user` 的模式里：人输错位数时，模式永远匹配不上，脚本要么一直干等（`timeout -1`），要么超时后因为 `$expect_out(1,string)` 不存在而报错（我实测过这两种情况）。更稳的写法是先读一整行，再用 `regexp` 检查：

```tcl
send_user "请输入六位验证码: "
expect_user -re {([^\r\n]*)\r?\n}
set otp [string trim $expect_out(1,string)]
if {![regexp {^[0-9]{6}$} $otp]} {
    puts stderr "\nOTP 必须是 6 位数字，已停止"
    catch {close}; catch {wait}
    exit 1
}
send -- "$otp\r"
set otp ""                             ;# 发完立刻清空
```

安全上还要注意：验证码不要写进日志；条件允许时关闭终端回显（见 2.11）；无论成功还是异常，都要恢复回显。

### 2.8 `interact`：把键盘交还给人

```tcl
spawn ssh user@host
expect "password:"
send "secret\r"
interact                               ;# 之后人直接和 ssh 对话
```

脚本不再需要人参与时，通常用 `expect eof` 而不是 `interact`（后者依赖 stdin，没有终端时行为不稳）。

**`interact` 和 `expect_user` 有什么区别？** 两者容易混淆：

| | `expect_user` | `interact` |
|---|---|---|
| 做什么 | 脚本**主动等人输入一小段内容**，通常随后用 `send` 转给子进程 | 把你的终端和子进程**直接连通**，人接管整个交互 |
| 谁掌控流程 | 脚本 | 人 |
| 适合 | 读取验证码这样"读一下、检查一下、再发送"的短输入 | 脚本完成登录后，想让人继续手动操作 |

验证码是一次短输入、需要检查格式，所以用 `expect_user`。如果连接成功后还想让人随时手动操作 openconnect，才考虑 `interact`。

### 2.9 退出码：`wait`

```tcl
expect eof
set result [wait]                      ;# {pid spawn_id 0 退出码}
exit [lindex $result 3]                ;# 把被控程序的退出码传出去
```

三个容易混淆的概念：

| 名称 | 含义 |
|---|---|
| `eof` | 子进程关闭了输出通道或已退出（`expect eof` 就是等到这一刻） |
| `wait` | **回收**子进程，并取得退出状态；不回收会留下僵尸进程 |
| `close` | 关闭 Expect 与子进程之间的通道 |

`wait` 返回的列表里，退出码在索引 3。如果子进程已经被回收过，再次 `wait` 会报错，所以清理路径上常写成 `catch {wait}`。

### 2.10 日志与输出控制

```tcl
log_user 0                             ;# 不把被控程序的输出显示在屏幕上
log_user 1                             ;# 显示（默认）
log_file /tmp/session.log              ;# 记录到文件（注意：会记下密码回显，慎用）
```

`log_user 0` 只是不显示子进程输出，**不等于**敏感信息被清除。几条安全习惯：

- 不要在脚本里打印密码、验证码、Cookie、令牌（写 `puts "Password submitted."`，不要写 `puts "password=$pw"`）。
- 排障时不要把完整的认证报文贴到公开聊天或工单里；必须贴时，对用户名、IP、Cookie、令牌、验证码脱敏。

### 2.11 密码输入不回显

```tcl
stty -echo
send_user "Password: "
expect_user -re "(.*)\n"
send_user "\n"
stty echo
set pw $expect_out(1,string)
```

### 2.12 信号处理

```tcl
trap {
    catch {exec kill -TERM $pid}
    exit 0
} {SIGTERM SIGINT}
```

容器里 `docker stop` 发送 SIGTERM，不处理的话子进程可能没机会优雅退出。

两点提醒：

- `exec kill` 调用的是系统里的 `kill` **可执行文件**。精简的 Docker 镜像里不一定有它（Debian 里通常由 `procps` 包提供），这时 `exec kill` 会失败。所以脚本里才写成 `catch {exec kill ...}`，失败了也不会让脚本崩溃，但信号就没转发出去。是否有 `kill`，可以在容器里用 `which kill` 确认；没有的话，装 `procps`，或改用 `exec sh -c "kill -TERM $pid"`（用 shell 自带的 `kill`）。我在沙箱里验证了这两种写法都能工作，但那个环境装有 `procps`，没有在精简镜像里实测。
- 生产脚本还应考虑：子进程是否已经退出、是否要 `wait` 回收、输入验证码期间被中断时是否要恢复终端回显。

### 2.13 调试利器

```tcl
exp_internal 1                         ;# 打印 Expect 内部匹配过程
```

它会显示"缓冲区里现在是什么、正在拿哪个模式去匹配、是否命中"。脚本"卡住不动"或"没匹配上"时，第一步就开它。排查完用 `exp_internal 0` 关掉。

提醒：调试输出里可能带有服务端返回的认证文本，**`exp_internal` 不是脱敏工具**。不要把含密码、验证码、Cookie、会话令牌或内部地址的原始调试日志直接发到公开渠道。

### 2.14 动手：写你的第一个 Expect 脚本

不要一上来就改真实 VPN 脚本。先用一个**自己造的模拟程序**练习，没有任何风险，也不会触发账号锁定。

**第 1 步：确认安装。**

```bash
sudo apt-get update && sudo apt-get install -y expect     # Debian / Ubuntu
brew install expect                                        # macOS（本机学习用）
expect -v                                                  # 看到版本号即成功
```

本项目里 Expect 装在 Debian 容器内，所以以**容器内**的 `expect -v` 为准。

**第 2 步：自动回答一个 Password 提示。** 创建 `demo1.exp`：

```tcl
#!/usr/bin/expect -f

set timeout 30

# 用 sh -c 造一个会问 Password、读一行、再回显的"假程序"
spawn sh -c {printf "Password: "; read value; echo "received"}

expect {
    -re {Password:} {
        send -- "demo-password\r"
    }
    timeout {
        puts stderr "prompt timeout"
        exit 2
    }
    eof {
        puts "child exited"
    }
}

expect eof
wait
```

运行 `expect -f demo1.exp`，应该能看到 `received`。（密码是占位值，不要在脚本里写真实密码。）

**第 3 步：让人输入验证码。** 创建 `demo2.exp`：

```tcl
#!/usr/bin/expect -f

set timeout -1

spawn sh -c {printf "Please input SMS Code: "; read code; echo "code received: $code"}

expect {
    -re {Please input SMS Code:} {
        send_user "请输入六位验证码: "
        expect_user -re {([^\r\n]*)\r?\n}
        set otp [string trim $expect_out(1,string)]
        if {![regexp {^[0-9]{6}$} $otp]} {
            puts stderr "\nOTP 必须是 6 位数字，已停止"
            catch {close}; catch {wait}
            exit 1
        }
        send -- "$otp\r"
        set otp ""
    }
    eof {
        puts "child exited unexpectedly"
        exit 1
    }
}

expect eof
wait
```

运行后输入 `123456`，会看到 `code received: 123456`；输入 `12345`，会提示格式错误并以退出码 1 结束。这两个脚本我都实际跑过。

**第 4 步：学会"先观察，再自动化"。** 第一次控制一个陌生程序时，不要立刻写复杂的正则：

1. 先在终端里**手动**运行原始命令；
2. 记录程序**实际**输出的提示（逐字，包括大小写和标点）；
3. 确定哪些提示要自动回答，哪些要交给人；
4. 为每个提示写一个独立的匹配分支；
5. 加上超时、EOF 和失败分支；
6. 最后才加自动重连、信号处理这类高级逻辑。

这样能避开"正则猜错""认证状态顺序搞错"这类问题。这次 OpenConnect 的排查就是这个思路：先手动跑 openconnect 确认服务端行为，再让 Expect 去自动化输入。

---

## 第三部分：常见陷阱（都是真实踩过的）

### 陷阱 1：多模式时，匹配的是**列表顺序**，不是输出出现的先后

```tcl
expect {
    -re {Password:}      { ... }        ;# 先写
    -re {Login failed}   { ... }        ;# 后写
}
```

如果缓冲区里同时有 `Login failed. ... Password:`，Expect 会拿**第一个模式**先去试，命中 `Password:`，于是 `Login failed` 被忽略了。
**解法**：把"失败/终止类"模式放在前面，"需要回应"的模式放在后面。

**这个办法的局限：** 模式顺序只在"两段输出已经同时在缓冲区里"时才起作用。如果 `Password:` 先到达、脚本已经处理它之后，`Login failed` 才输出，顺序就帮不上忙了。更可靠的做法是把流程设计成明确的状态（比如用 `password_sent` 这样的标志位），并用 `--dump-http-traffic` 之类的手段，实际确认服务端的输出顺序。

### 陷阱 2：同一个提示被多种语言输出，导致重复匹配

服务端依次输出"请输入短信验证码:"和"Please input SMS Code:"。如果两个都写进模式，第一个处理完后第二个还躺在缓冲区里，会触发第二次"又在要验证码"。
**解法**：只匹配其中一种。

### 陷阱 3：`\r` 和 `\n`

向程序"按回车"用 `\r`；匹配程序输出里的换行用 `\r?\n`（终端输出的换行常是 `\r\n`）。

### 陷阱 4：通配符里的 `[`

默认的 glob 模式里 `[abc]` 是字符集。在**双引号**里 `[` 还会触发 Tcl 命令替换。匹配字面量 `[` 用花括号加 `-ex`：

```tcl
expect -ex {[INFO]}
```

### 陷阱 5：`send` 太快

有些程序在提示出现前就丢弃输入。永远先 `expect` 提示，再 `send`。

### 陷阱 6：`exp_continue` 忘写

动作里没写 `exp_continue`，`expect` 就直接结束，脚本往下走，后面的提示没人处理。

### 陷阱 7：`}` 与 `else` 不在同一行

```tcl
if {$x} {
    ...
}
else {        ;# 错误：Tcl 以为 if 已经结束
```

### 陷阱 8：expr 不加花括号

写成 `expr $a + $b` 能跑，但应该写 `expr {$a + $b}`。

### 陷阱 9：`expect { ... }` 花括号里的注释位置

`expect` 的分支块里，注释必须**单独占一行**写。写在动作的 `}` 后面（比如 `{ ... }  # 说明`），`#` 会被当成下一个模式，导致报错。

---

## 第四部分：示例应用

下面的例子都可以直接改改就用。先是纯 Tcl（用 `tclsh` 运行），再是 Expect。

### 4.1 纯 Tcl 示例

**示例 1：统计日志里各级别出现的次数**

```tcl
#!/usr/bin/env tclsh
set f [open "app.log" r]
array set count {}

while {[gets $f line] >= 0} {
    # -> 只是个变量名，接收整个匹配；level 接收括号里的分组
    if {[regexp {\[(ERROR|WARN|INFO)\]} $line -> level]} {
        if {![info exists count($level)]} { set count($level) 0 }
        incr count($level)
    }
}
close $f

foreach level [lsort [array names count]] {
    puts "$level: $count($level)"
}
```

用到了：文件读取（1.11）、正则（1.8）、数组（1.7）、循环（1.5）。

**示例 2：用 dict 管理配置**

```tcl
set cfg [dict create host 127.0.0.1 port 8888]
dict set cfg timeout 30
dict for {k v} $cfg { puts "$k = $v" }
puts "代理地址: http://[dict get $cfg host]:[dict get $cfg port]"
```

`dict` 比数组更适合"当作一个值整体传来传去"，比如传给 `proc`。

**示例 3：十行代码的 TCP 服务**

```tcl
proc accept {chan addr port} {
    fconfigure $chan -buffering line
    puts $chan "hello $addr"
    close $chan
}
socket -server accept 9000
puts "listening on 9000"
vwait forever            ;# 进入事件循环，等连接
```

另开一个终端 `nc localhost 9000` 就能看到回复。这就是 Tcl "自带事件循环和 socket"的体现。

### 4.2 Expect 示例

**示例 4：自动 SSH 登录并执行一条命令**

```tcl
#!/usr/bin/expect -f
set timeout 20
set host [lindex $argv 0]
set cmd  [lindex $argv 1]

spawn ssh -o StrictHostKeyChecking=accept-new user@$host $cmd
set sent 0
expect {
    -re {(?i)password:} {
        if {$sent} { puts stderr "password rejected"; exit 2 }
        send -- "$env(SSH_PASSWORD)\r"
        set sent 1
        exp_continue
    }
    timeout { puts stderr "timeout"; exit 1 }
    eof
}
catch wait result
exit [lindex $result 3]
```

运行：`SSH_PASSWORD=xxx ./ssh_run.exp 10.0.0.5 "uptime"`。

要点：密码走环境变量而不是写进脚本；用 `sent` 标志避免密码错误时无限重试；最后把远端命令的退出码传出去。能用**密钥登录**的场景应该优先用密钥，Expect 是没有别的办法时的选择。

**示例 5：批量巡检多台设备**

```tcl
#!/usr/bin/expect -f
set timeout 15
set hosts {10.0.0.1 10.0.0.2 10.0.0.3}

proc inspect {h} {
    spawn ssh -o StrictHostKeyChecking=accept-new admin@$h
    expect {
        -re {(?i)password:} { send -- "$::env(DEV_PASSWORD)\r"; exp_continue }
        -re {[#>$] $}       { }
        timeout             { puts "$h: timeout"; catch {close}; catch {wait}; return }
    }
    send "show version\r"
    expect -re {[#>$] $}
    puts "=== $h ===\n$expect_out(buffer)"
    send "exit\r"
    expect eof
    catch {wait}
}

foreach h $hosts { inspect $h }
```

要点：`proc` 里读环境变量要写 `$::env(...)`（`::` 表示全局）；提示符用正则 `[#>$] $` 匹配常见的设备和 shell 提示符；失败的设备打印后跳过，不影响后面的。

**示例 6：自动应答安装程序的确认提示**

```tcl
#!/usr/bin/expect -f
set timeout 300
spawn ./install.sh
expect {
    -re {Continue\? \[y/n\]} { send "y\r"; exp_continue }
    -re {Press ENTER}        { send "\r"; exp_continue }
    eof
}
```

这是 Expect 最经典的用法：程序"问一句、等人答一句"，脚本替人答。

**示例 7：测试一个交互式命令行程序**

```tcl
#!/usr/bin/expect -f
set timeout 5
spawn ./mycli
expect "> "
send "add 1 2\r"
expect {
    "3"     { puts "PASS" }
    timeout { puts "FAIL: no result"; exit 1 }
}
send "quit\r"
expect eof
```

自己写了个带 REPL 的小工具，想做自动化测试，就是这个套路：`send` 一条命令，`expect` 期望的输出，对不上就以非零退出码失败，方便接进 CI。

**示例 8：本项目的 `openconnect.exp`**

它是同一个套路的实际应用：`spawn` 启动 openconnect → 等 `Password:` 自动发密码 → 等 `Please input SMS Code:` 转给人输入 → 等 `Configured as` 表示成功。完整代码见仓库中的 `docker/openconnect.exp`。

---

## 第五部分：练习

建议每天 30 至 45 分钟，**按顺序**做。不要一开始就改真实的 VPN 脚本。每题都给了"目标"，卡住时看"提示"。

### 练习 1：Tcl 变量和输出

```tcl
set name "Tcl"
set version 8.6
puts "Learning $name $version"
```

目标：理解 `set`、`puts`、`$变量`、双引号。试着把双引号换成花括号，看输出有什么变化。

### 练习 2：列表和循环

```tcl
set services [list api worker scheduler]
foreach service $services {
    puts "service=$service"
}
```

目标：理解 `list`、`foreach`、列表元素边界。进阶：往列表里加一个带空格的元素 `"my service"`，用 `llength` 看长度是不是你预期的。

### 练习 3：条件和正则

```tcl
set otp "123456"
if {[regexp {^[0-9]{6}$} $otp]} {
    puts "format ok"
} else {
    puts "invalid format"
}
```

目标：理解表达式、`regexp`、花括号。试试 `"12345"`、`"abcdef"`、`" 123456"`（带前导空格），再用 `string trim` 修正最后一个。

### 练习 4：数组和字典

写一个脚本，统计字符串 `"a b a c b a"` 里每个单词出现的次数，用数组存，最后按字母顺序打印。再用 `dict` 改写一遍。

目标：掌握 `array set` / `info exists` / `incr` / `dict set` / `dict for` / `lsort`。

提示：先 `foreach w [split $str " "] { ... }` 逐个取词；`lsort [array names count]` 取排序后的键。

### 练习 5：Expect 自动回答一个问题

用 `sh -c {printf "Password: "; read v; echo "got $v"}` 造一个测试程序，让 Expect 自动发送一个测试密码。再试一个变体：`spawn bash`，等 `$ ` 提示，发送 `echo hi`，打印输出后退出。

目标：掌握 `spawn`、`expect`、`send`，以及"先 `expect` 提示，再 `send`"。

### 练习 6：两个阶段的认证

让测试程序先提示 `Password:`，再提示 `Please input SMS Code:`。Expect 自动发送第一个值，再用 `expect_user` 读取第二个值并转交。

目标：掌握多阶段 `expect`、`exp_continue`、`expect_user`。

### 练习 7：失败和超时

在测试程序里增加两种情况：输出 `Login failed`；或者长时间不输出任何东西。让 Expect 能分别识别**失败、EOF、timeout** 三种情况，并给出不同的退出码。

目标：掌握健壮的错误处理。提示：失败模式放前面（陷阱 1）；记得用 `catch {close}; catch {wait}` 清理。

### 练习 8：命令行参数

写一个脚本，接收一个程序路径作为命令行参数（用 `lindex $argv 0`），对会问 `Continue? [y/n]` 的程序自动回答 `y`。

目标：掌握 `$argv`、把脚本写成可复用的小工具。

### 练习 9：进程生命周期

让被控程序持续运行（比如 `sleep 60`）。分别测试：`expect eof` + `wait`、给脚本发 `SIGTERM`（配合 `trap` 转发给子进程）、`interact`。

目标：理解"脚本结束"和"子进程结束"是两回事；理解 `trap` 的作用。

### 练习 10：给 `openconnect.exp` 加一个可选的 `VPN_OTP`

如果环境变量 `VPN_OTP` 存在，就直接发送，不再等人输入。

目标：读懂并修改真实脚本。提示：在 `Please input SMS Code:` 分支里先判断 `[info exists env(VPN_OTP)]`。**注意**：验证码有时效，而且放在环境变量里会被 `docker inspect` 看到，这个练习只用于学习，不要在生产里这样用。

### 练习 11：给调试输出加一个开关

用环境变量 `EXPECT_DEBUG` 控制是否执行 `exp_internal 1`。

目标：理解 2.13 的调试方法，以及"调试输出可能含敏感信息"这一点。

### 练习 12：回到 OpenConnect

只有前面都做完，再测试真实 VPN。**先手动运行 openconnect** 验证服务端认证行为，再让 Expect 负责输入自动化。

目标：把协议问题、认证问题、Expect 输入问题和 Docker 网络问题**分层定位**，不要混在一起查。

---

## 第六部分：延伸

### 6.1 Expect、Shell、Python、Ansible 怎么选

| 技术 | 最擅长 | 不擅长 |
|---|---|---|
| Shell | 启动命令、文件处理、管道、系统编排 | 复杂交互状态管理、复杂数据结构 |
| Tcl + Expect | 自动化终端交互：等提示、再输入 | 大型业务逻辑、复杂 API 数据处理 |
| Python | API、数据处理、复杂流程、测试框架 | 控制老式终端交互需要额外的库 |
| Python + Pexpect | 在 Python 项目里控制交互式命令行 | 同样依赖终端提示稳定，边界和 Expect 一样 |
| Ansible | 服务器配置管理、批量自动化 | 不适合所有持续运行的交互式会话 |
| Playwright | 浏览器页面自动化 | 不是通用的终端交互工具 |

### 6.2 Shell 和 Expect 的分工

Shell 更像"命令编排器"：

```bash
apt-get update
apt-get install -y openconnect
ip route
```

Expect 更像"交互操作者"：

```tcl
spawn some-command
expect "Password:"
send -- "$password\r"
```

实际项目经常两者配合。你这次的方案就是：Docker 和 `entrypoint.sh`（Shell）负责安装和启动 tinyproxy，Expect 负责 OpenConnect 的交互认证。

### 6.3 Python 和 Pexpect

如果团队主要用 Python，可以考虑 **Pexpect**。它提供类似的 `spawn`、`expect`、`sendline` 能力，概念和 Expect 一一对应：

```python
import pexpect

child = pexpect.spawn("ssh user@example.com")
child.expect("Password:")
child.sendline("example-password")
```

如果现有的 Expect 脚本已经解决了问题，**没有必要仅仅因为 Tcl 陌生就全部迁移**。选工具要看维护成本、运行环境和团队能力。

### 6.4 什么时候该迁出 Expect

出现下面这些情况，可以考虑 Python/Pexpect，或者换成正式 API：

- 状态分支越来越多；
- 需要结构化日志、并发任务和监控指标；
- 需要支持多种不同的认证后端；
- 需要保存任务状态并跨进程恢复；
- 需要复杂的重试、退避和故障恢复策略。

如果只是"启动 CLI → 输入密码 → 输入验证码 → 保持进程"，Expect 仍然是简单直接的工具。

### 6.5 其他资源

- **autoexpect**：Expect 自带的录制工具，能把一次人工操作录成脚本，适合起步，但生成的脚本很啰嗦，需要手工精简。
- **书籍**：Don Libes 的《Exploring Expect》是权威著作。
- **安全提醒**：脚本里避免用 `log_file` 记录会话（会记下密码）；密码不要硬编码，用环境变量或 secrets 传入；用完及时 `set pw ""` 并 `unset env(...)`，就像 `openconnect.exp` 里做的那样。

---

## 附录 A：速查表

写脚本时快速翻查。这不是完整的语言规范，只围绕本教程用到的命令整理。

### A.1 Tcl 语法

| 写法 | 意义 |
|---|---|
| `set x 1` | 定义变量 |
| `$x` | 读取变量 |
| `"..."` | 双引号：一个整体，**做**变量和命令替换 |
| `{...}` | 花括号：原样保护，**不做**替换，用于代码块和正则 |
| `[...]` | 命令替换：先执行里面的命令，用结果替换 |
| `;` | 在同一行分隔多条命令；行尾注释写成 `;# ...` |
| `if {...} {...} else {...}` | 条件判断（`}` 与 `else` 必须在同一行） |
| `eq` / `ne` | 字符串相等 / 不等；数字用 `==` / `!=` |
| `foreach x $list {...}` | 遍历列表 |
| `for {...} {...} {...} {...}` / `while {...} {...}` | 循环 |
| `list a b c` / `lappend l v` / `lindex $l 0` / `llength $l` | 列表创建、追加、取元素、长度 |
| `lsort $l` | 列表排序 |
| `{*}$list` | 把列表展开成多个独立参数 |
| `array set a {k v ...}` / `$a(k)` / `info exists a(k)` | 数组 |
| `dict create` / `dict set d k v` / `dict get $d k` / `dict for {k v} $d {...}` | 字典 |
| `$env(NAME)` / `$::env(NAME)` | 环境变量（在 `proc` 里要写 `$::env`） |
| `expr {...}` | 数学和逻辑运算，**表达式永远加花括号** |
| `string trim / length / range / match / map` | 字符串操作 |
| `regexp {pattern} $s all g1 g2` | 正则匹配，分组放进变量 |
| `proc name {args} {...}` | 定义过程 |
| `catch {...} result` | 捕获错误，返回 0 表示成功 |
| `open` / `gets` / `read` / `close` | 文件读写 |
| `exec cmd args` | 执行外部命令 |
| `unset x` | 删除变量 |
| `exit 1` | 退出脚本 |

### A.2 Expect 命令

| 写法 | 意义 |
|---|---|
| `spawn command` | 启动被控程序 |
| `expect "text"` | 等待指定文本（glob 匹配） |
| `expect -re {regex}` / `expect -ex "text"` | 正则匹配 / 精确字符串匹配 |
| `expect { pattern {action} ... }` | 多分支：按**列表顺序**检查，匹配到第一个就执行 |
| `timeout` / `eof` / `default` | 特殊模式：超时 / 子进程结束 / 二者之一 |
| `send -- "value\r"` | 向被控程序发送输入（回车写 `\r`） |
| `send_user "text"` | 向你自己的屏幕输出 |
| `expect_user -re {...}` | 等待你的键盘输入 |
| `exp_continue` | 处理完当前提示后继续等待 |
| `$expect_out(1,string)` | 第 1 个正则分组匹配到的内容 |
| `interact` | 把终端交给人 |
| `expect eof` | 等被控进程结束 |
| `wait` | 回收被控进程；`lindex $result 3` 是退出码 |
| `exp_pid` | 取子进程 PID |
| `trap {...} {SIGTERM SIGINT}` | 捕获系统信号 |
| `log_user 0/1` | 隐藏 / 显示子进程输出 |
| `stty -echo` / `stty echo` | 关闭 / 恢复终端回显 |
| `set timeout 30` / `set timeout -1` | 等待 30 秒 / 永不超时（默认 10 秒） |
| `exp_internal 1` | 打开 Expect 内部调试输出 |

### A.3 读一个 Expect 分支的固定思路

看到这样的分支：

```tcl
-re {PATTERN} {
    ACTIONS
    exp_continue
}
```

按下面的顺序理解：

1. `-re` 后面的正则在匹配**什么输出**？
2. 匹配后进入哪段代码？
3. 其中的 `send` 是发给子进程，还是 `send_user` 发给人？
4. 有没有"已经发送"之类的状态变量，防止重复提交？
5. `exp_continue` 是继续等下一个状态，还是让分支直接结束？
6. 失败、超时、EOF 这三种情况有没有处理？

---

## 附录 B：官方资料

以下链接我都实际打开确认过能访问：

1. **Expect 官方手册**：<https://core.tcl-lang.org/expect/doc/trunk/expect.man>
   查 `spawn`、`expect`、`send`、`expect_user`、`interact`、`trap` 等命令。
2. **Tcl 8.6 命令参考**：<https://www.tcl-lang.org/man/tcl8.6/TclCmd/contents.htm>
   查 `set`、`if`、`foreach`、`list`、`proc`、`catch`、`regexp` 等 Tcl 命令。
3. **Tcl 官方网站**：<https://www.tcl-lang.org/>
   Tcl 语言、下载和教程资料。
4. **OpenConnect 官方手册**：<https://www.infradead.org/openconnect/manual.html>
   查 `--protocol`、`--authgroup`、`--useragent`、`--version-string`、`--no-dtls` 等客户端选项。
5. **OpenConnect 项目主页（GitLab）**：<https://gitlab.com/openconnect/openconnect>
   需要研究认证表单、CSTP、DTLS 或不同版本行为时，可以查看实现。

---

## 结语：学会 Expect，重点是掌握"交互状态机"

Tcl 是一门通用脚本语言；Expect 是建立在 Tcl 之上的交互自动化扩展。你不需要一开始就把 Tcl 的所有特性学完。

对当前的 OpenConnect 项目，最重要的是理解这条主线：

```text
spawn
  启动 OpenConnect
    ↓
expect
  等待 Password / SMS Code / Login failed / Configured as
    ↓
send / expect_user
  自动输入主密码，人工输入验证码
    ↓
exp_continue
  继续处理下一个认证状态
    ↓
expect eof / wait
  保持隧道进程，并回收退出的子进程
```

掌握 Tcl 的变量、列表、条件、正则和过程，再理解 Expect 的 `spawn → expect → send → exp_continue → wait`，就已经具备阅读和维护大多数常见 Expect 脚本的基础。

**学习建议：先用不含敏感信息的模拟程序练习，再把成熟的小片段用于真实 VPN。**
