# AppKit 文本输入控件调研

## 结论

单行输入统一使用原生 `NSTextField`，保留 `placeholderString` / `placeholderAttributedString`，不要在外层再复制一套 placeholder 状态机。Apple 将 `NSTextField` 定义为简单文本编辑控件，并明确提供 placeholder API；`NSTextFieldCell` 负责文本字段的绘制和编辑。

多行输入统一使用 `NSTextView`（通常通过 `NSTextView.scrollableTextView()` 放入滚动容器），用 `textContainerInset` 设置内边距。`NSTextView` 原生支持输入法 marked text、文本存储和插入符，因此多行 placeholder 若产品需要，应只做一个通用的 view 组合，而不是每个调用点各自实现。

参考：

- [NSTextField](https://developer.apple.com/documentation/appkit/nstextfield)
- [NSTextFieldCell](https://developer.apple.com/documentation/appkit/nstextfieldcell)
- [NSTextView](https://developer.apple.com/documentation/appkit/nstextview)
- [Cocoa Text Architecture Guide: Text Fields, Text Views, and the Field Editor](https://developer.apple.com/library/archive/documentation/TextFonts/Conceptual/CocoaTextArchitecture/TextFieldsAndViews/TextFieldsAndViews.html)

## AppKit 的职责边界

### 单行字段

推荐直接配置 `NSTextField`：

```swift
let field = NSTextField()
field.placeholderString = "Task name"
field.isBezeled = false
field.drawsBackground = false
field.focusRingType = .none
field.font = .systemFont(ofSize: 12.5)

if let cell = field.cell as? NSTextFieldCell {
    cell.usesSingleLineMode = true
    cell.wraps = false
    cell.isScrollable = true
}
```

内边距和背景可以由外层容器通过 Auto Layout 和 layer 提供，但容器不应重画 placeholder、插入符或 field editor。已有的搜索岛正是这个方向：`NSTextField` 自己持有原生 placeholder，外层只负责岛的背景和布局。

### field editor 和输入法

AppKit 会让窗口内的多个控件共享一个 field editor。字段获得焦点时，field editor 临时接管输入和绘制；编辑结束时，内容同步回 `NSTextFieldCell`。因此不应假设“字段静态绘制的文字”和“编辑器绘制的文字”是同一条绘制路径，也不应通过修改 `lineFragmentPadding` 或自绘 placeholder 来修补它们的差异。

如果业务确实需要监听 marked text，Apple 提供了 `NSTextFieldCell.setWantsNotificationForMarkedText(_:)`；只有在业务逻辑必须知道拼字过程时才使用它。placeholder 显示本身不应依赖这类通知，应该交给原生 cell。

参考：

- [Working With the Field Editor](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/TextEditing/Tasks/FieldEditor.html)
- [`setWantsNotificationForMarkedText(_:)`](https://developer.apple.com/documentation/appkit/nstextfieldcell/setwantsnotificationformarkedtext(_:))
- [`setUpFieldEditorAttributes(_:)`](https://developer.apple.com/documentation/appkit/nstextfieldcell/setupfieldeditorattributes(_:))

### 多行字段

`NSTextView` 是 AppKit 的多行文本编辑控件，并原生处理 marked text。`textContainerInset` 是官方提供的文本容器内边距，不需要通过修改 field editor 或手工猜测文字起点来对齐。

多行 placeholder 没有对应的 `NSTextView.placeholderString` API。项目应保留一个统一的 `ShellTextArea` 组件来封装这一缺口：它可以包含一个非交互的 placeholder label，但 marked text、文本变化和插入符仍由内部 `NSTextView` 管理。所有多行字段只调用这个组件，不在业务层实现 placeholder。

参考：[NSTextView `textContainerInset`](https://developer.apple.com/documentation/appkit/nstextview/textcontainerinset)

## 对重构前实现的判断

重构前的 `ShellFieldBox` 的可接受职责是：统一背景、圆角、尺寸和布局。仅为任务名称增加的自绘 placeholder、field editor 的 text storage 监听和 marked text 判断，是为绕过单行字段布局跳动而加入的 workaround：

```swift
ShellFieldBox(nameField, placeholder: L("Task name"))
```

这不是理想的原生实现，原因是：

1. `NSTextField` 已经拥有官方 placeholder 语义和无障碍支持；外层 label 会产生第二个文本元素。
2. 需要监听 field editor 生命周期和 marked text，增加了共享 field editor 下的状态管理。
3. 目前只有任务名称走这条路径，和搜索框、重命名框、设置字段形成了多种实现。
4. 光标宽度、baseline、输入法和文本绘制都不应由业务容器推测。

## 已采用的重构方向

1. `ShellFieldBox` 已收敛为纯布局/装饰容器：只接收一个 `NSTextField`，不包含 placeholder label、通知监听或 field editor 逻辑。
2. 任务名称已恢复 `nameField.placeholderString = L("Task name")`，与搜索框和其他单行字段使用同一套 AppKit 语义。
3. 单行字段的公共配置已收敛为 `ShellTextFieldStyle.configure(_:)`；调用点只提供字体和 placeholder 等语义差异。
4. 继续使用统一 `ShellTextArea` 作为多行组件，placeholder 和 marked text 处理均封装在组件内部；业务页面不再复制。
5. 回归测试验证语义和输入法行为：原生 placeholder 存在、文本字段保持单行；不测试 2pt/像素等 AppKit 内部实现细节。

## 不推荐的方案

- 自绘单行 placeholder 并同步 `NSTextStorage`。
- 修改 field editor 的 `lineFragmentPadding` 以“校准”光标或文字。
- 通过重写 `NSTextFieldCell.titleRect`、`drawingRect` 或 `edit(withFrame:)` 修补单个字段的像素偏移。
- 为每个页面分别实现单行/多行输入框。

这些方案要么重复 AppKit 已有职责，要么依赖当前系统版本的内部布局细节，不能成为项目级输入控件约定。
