import UIKit

/// Pixel-calibrated 1:1 Native iOS 26 Emoji keyboard featuring:
/// - Top rounded capsule search bar (`🔍 搜索表情符号`) with 100% offline quick-tag filtering
/// - 4-row × 8-column horizontal-scrolling Emoji grid (`36pt` glyphs, column-major flow)
/// - 9-category bottom dock (`🕒 😀 🐶 🍎 ⚽ 🚗 💡 ♡ ⚐`) with crisp outline icons & circular selection pill
/// - Borderless `拼音` return button & borderless `⌫` accelerated repeat backspace
final class EmojiKeyboardView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private enum IconSource {
        case custom(() -> UIImage)
        case sfSymbol(String, CGFloat)
    }

    private struct StaticCategory {
        let name: String
        let icon: IconSource
        let emojis: [String]
    }

    private struct QuickFilterTopic {
        let title: String
        let emojis: [String]
    }

    // MARK: - Callbacks & State

    var onInsertEmoji: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    var onSwitchToKeyboard: (() -> Void)?

    var switchButtonTitle: String = "拼音" {
        didSet {
            if oldValue != switchButtonTitle {
                switchButton.setTitle(switchButtonTitle, for: .normal)
            }
        }
    }

    // MARK: - Categories Data

    private static let staticCategories: [StaticCategory] = [
        StaticCategory(
            name: "表情与人物",
            icon: .custom({ KeyboardTheme.nativeEmojiFaceImage(pointSize: 17.0) }),
            emojis: [
                "😀", "😃", "😄", "😁", "😆", "😅", "🤣", "😂", "🙂", "🙃", "🫠", "😉", "😊", "😇",
                "🥰", "😍", "🤩", "😘", "😗", "☺️", "😚", "😙", "🥲", "😋", "😛", "😜", "🤪", "😝",
                "🤑", "🤗", "🫣", "🤭", "🫢", "🫡", "🤫", "🤔", "🤐", "🤨", "😐", "😑", "😶", "🫥",
                "😏", "😒", "🙄", "😬", "😮‍💨", "🤥", "🫨", "😌", "😔", "😪", "🤤", "😴", "😷", "🤒",
                "🤕", "🤢", "🤮", "🤧", "🥵", "🥶", "🥴", "😵", "😵‍💫", "🤯", "🤠", "🥳", "🥸", "😎",
                "🤓", "🧐", "😕", "🫤", "😟", "🙁", "☹️", "😮", "😯", "😲", "😳", "🥺", "🥹", "😦",
                "😧", "😨", "😰", "😥", "😢", "😭", "😱", "😖", "😣", "😞", "😓", "😩", "😫", "🥱",
                "😤", "😡", "😠", "🤬", "😈", "👿", "💀", "☠️", "💩", "🤡", "👹", "👺", "👻", "👽",
                "👾", "🤖", "👋", "🤚", "🖐️", "✋", "🖖", "🫱", "🫲", "🫳", "🫴", "🫷", "🫸", "👌",
                "🤌", "🤏", "✌️", "🤞", "🫰", "🤟", "🤘", "🤙", "👈", "👉", "👆", "🖕", "👇", "☝️",
                "🫵", "👍", "👎", "✊", "👊", "🤛", "🤜", "👏", "🙌", "🫶", "👐", "🤲", "🤝", "🙏",
                "✍️", "💅", "🤳", "💪"
            ]
        ),
        StaticCategory(
            name: "动物与自然",
            icon: .custom({ KeyboardTheme.nativeEmojiDogIcon(pointSize: 19.0) }),
            emojis: [
                "🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐻‍❄️", "🐨", "🐯", "🦁", "🐮", "🐷",
                "🐽", "🐸", "🐵", "🙈", "🙉", "🙊", "🐒", "🐔", "🐧", "🐦", "🐤", "🐣", "🐥", "🦆",
                "🦅", "🦉", "🦇", "🐺", "🐗", "🐴", "🦄", "🐝", "🪱", "🐛", "🦋", "🐌", "🐞", "🐜",
                "🪰", "🪲", "🪳", "🦟", "🦗", "🕷️", "🕸️", "🦂", "🐢", "🐍", "🦎", "🦖", "🦕", "🐙",
                "🦑", "🦐", "🦞", "🦀", "🐡", "🐠", "🐟", "🐬", "🐳", "🐋", "🦈", "🦭", "🐊", "🐆",
                "🐅", "🐃", "🐂", "🐄", "🐪", "🐫", "🦙", "🦒", "🐘", "🦣", "🦏", "🦛", "🐁", "🐀",
                "🦔", "🐇", "🐿️", "🦫", "🦨", "🦡", "🦥", "🦦", "🦘", "🦬", "🌲", "🌳", "🌴", "🪵",
                "🌱", "🌿", "☘️", "🍀", "🎍", "🪴", "🍃", "🍂", "🍁", "🍄", "🐚", "🪨", "🌾", "💐",
                "🌷", "🌹", "🥀", "🌺", "🌸", "🌼", "🌻", "🌞", "🌝", "🌛", "🌜", "🌚", "🌕", "🌖",
                "🌗", "🌘", "🌑", "🌒", "🌓", "🌔", "🌙", "🌎", "🌍", "🌏", "🪐", "💫", "⭐️", "🌟",
                "✨", "⚡️", "☄️", "💥", "🔥", "🌪️", "🌈", "☀️", "🌤️", "⛅️", "🌥️", "☁️", "🌦️", "🌧️",
                "⛈️", "🌩️", "🌨️", "❄️", "☃️", "⛄️", "🌬️", "💨", "💧", "💦", "🫧", "☔️", "☂️", "🌊", "🌫️"
            ]
        ),
        StaticCategory(
            name: "食物与饮料",
            icon: .custom({ KeyboardTheme.nativeEmojiAppleIcon(pointSize: 18.0) }),
            emojis: [
                "🍏", "🍎", "🍐", "🍊", "🍋", "🍌", "🍉", "🍇", "🍓", "🫐", "🍈", "🍒", "🍑", "🥭",
                "🍍", "🥥", "🥝", "🍅", "🍆", "🥑", "🫛", "🥦", "🥬", "🥒", "🌶️", "🫑", "🌽", "🥕",
                "🫒", "🧄", "🧅", "🥔", "🍠", "🥐", "🥯", "🍞", "🥖", "🥨", "🧀", "🥚", "🍳", "🧈",
                "🥞", "🧇", "🥓", "🥩", "🍗", "🍖", "🦴", "🌭", "🍔", "🍟", "🍕", "🫓", "🥪", "🥙",
                "🧆", "🌮", "🌯", "🫔", "🥗", "🥘", "🫕", "🥫", "🍝", "🍜", "🍲", "🍛", "🍣", "🍱",
                "🥟", "🦪", "🍤", "🍙", "🍚", "🍘", "🍥", "🥠", "🥮", "🍢", "🍡", "🍧", "🍨", "🍦",
                "🥧", "🧁", "🍰", "🎂", "🍮", "🍭", "🍬", "🍫", "🍿", "🍩", "🍪", "🌰", "🥜", "🍯",
                "🥛", "🍼", "☕️", "🍵", "🧃", "🥤", "🧋", "🍶", "🍺", "🍻", "🥂", "🍷", "🥃", "🍸",
                "🍹", "🧉", "🍾", "🧊", "🥄", "🍴", "🍽️", "🥢"
            ]
        ),
        StaticCategory(
            name: "活动与运动",
            icon: .sfSymbol("soccerball", 14.5),
            emojis: [
                "⚽️", "🏀", "🏈", "⚾️", "🥎", "🎾", "🏐", "🏉", "🥏", "🎱", "🪀", "🏓", "🏸", "🏒",
                "🏑", "🥍", "🏏", "🪃", "🥅", "⛳️", "🪁", "🏹", "🎣", "🤿", "🥊", "🥋", "🎽", "🛹",
                "🛼", "🛷", "⛸️", "🥌", "🎿", "⛷️", "🏂", "🪂", "🏋️", "🤼", "🤸", "⛹️", "🤺", "🤾",
                "🏌️", "🏇", "🧘", "🏄", "🏊", "🤽", "🚣", "🧗", "🚵", "🚴", "🏆", "🥇", "🥈", "🥉",
                "🏅", "🎖️", "🏵️", "🎗️", "🎫", "🎟️", "🎪", "🤹", "🎭", "🩰", "🎨", "🎬", "🎤", "🎧",
                "🎼", "🎹", "🥁", "🪘", "🎷", "🎺", "🪗", "🎸", "🪕", "🎻", "🎲", "♟️", "🎯", "🎳",
                "🎮", "🎰", "🧩", "🎶"
            ]
        ),
        StaticCategory(
            name: "旅行与地点",
            icon: .custom({ KeyboardTheme.nativeEmojiCarSideIcon(pointSize: 18.5) }),
            emojis: [
                "🚗", "🚕", "🚙", "🚌", "🚎", "🏎️", "🚓", "🚑", "🚒", "🚐", "🛻", "🚚", "🚛", "🚜",
                "🦯", "🦽", "🦼", "🛴", "🚲", "🛵", "🏍️", "🛺", "🚨", "🚔", "🚍", "🚘", "🚖", "🚡",
                "🚠", "🚟", "🚃", "🚋", "🚞", "🚝", "🚄", "🚅", "🚈", "🚂", "🚆", "🚇", "🚊", "🚉",
                "✈️", "🛫", "🛬", "🛩️", "💺", "🛰️", "🚀", "🛸", "🚁", "🛶", "⛵️", "🚤", "🛥️", "🛳️",
                "⛴️", "🚢", "⚓️", "🛟", "⛽️", "🚧", "🚦", "🚥", "🚏", "🗺️", "🗿", "🗽", "🗼", "🏰",
                "🏯", "🏟️", "🎡", "🎢", "🎠", "⛲️", "🏖️", "🏝️", "🏜️", "🌋", "⛰️", "🏔️", "🏕️", "⛺️",
                "🏠", "🏡", "🏘️", "🏚️", "🏗️", "🏭", "🏢", "🏬", "🏣", "🏤", "🏥", "🏦", "🏨", "🏪",
                "🏫", "🏩", "💒", "🏛️", "⛪️", "🕌", "🕍", "🛕", "🕋"
            ]
        ),
        StaticCategory(
            name: "物品",
            icon: .sfSymbol("lightbulb", 14.5),
            emojis: [
                "⌚️", "📱", "📲", "💻", "⌨️", "🖥️", "🖨️", "🖱️", "🖲️", "🕹️", "🗜️", "💽", "💾", "💿",
                "📀", "📼", "📷", "📸", "📹", "🎥", "📽️", "🎞️", "📞", "☎️", "📟", "📠", "📺", "📻",
                "🎙️", "🎚️", "🎛️", "🧭", "⏱️", "⏲️", "⏰", "🕰️", "⌛️", "⏳", "📡", "🔋", "🪫", "🔌",
                "💡", "🔦", "🕯️", "🪔", "🧯", "🛢️", "💸", "💵", "💴", "💶", "💷", "🪙", "💰", "💳",
                "💎", "⚖️", "🪜", "🧰", "🪛", "🔧", "🔨", "⚒️", "🛠️", "⛏️", "🪓", "🪚", "🔩", "⚙️",
                "🪤", "🧱", "⛓️", "🧲", "🔫", "💣", "🧨", "🔪", "🗡️", "⚔️", "🛡️", "🚬", "⚰️", "🪦",
                "⚱️", "🏺", "🔮", "📿", "🧿", "💈", "⚗️", "🔭", "🔬", "🕳️", "🩹", "🩺", "💊", "💉",
                "🩸", "🧬", "🦠", "🧫", "🧪", "🌡️", "🧹", "🪠", "🧺", "🧻", "🧼", "🫧", "🪥", "🧽",
                "🪣", "🧴", "🔑", "🗝️", "🚪", "🪑", "🛋️", "🛏️", "🛌", "🧸", "🪆", "🖼️", "🪞", "🪟",
                "🛍️", "🛒", "🎁", "🎈", "🎏", "🎀", "🪄", "🪅", "🎊", "🎉", "🎎", "🏮", "🎐"
            ]
        ),
        StaticCategory(
            name: "符号",
            icon: .sfSymbol("heart", 15.0),
            emojis: [
                "❤️", "🧡", "💛", "💚", "💙", "💜", "🤎", "🖤", "🤍", "💔", "❤️‍🔥", "❤️‍🩹", "❣️", "💕",
                "💞", "💓", "💗", "💖", "💘", "💝", "💟", "☮️", "✝️", "☪️", "🕉️", "☸️", "✡️", "🔯",
                "🕎", "☯️", "☦️", "🛐", "⛎", "♈️", "♉️", "♊️", "♋️", "♌️", "♍️", "♎️", "♏️", "♐️",
                "♑️", "♒️", "♓️", "🆔", "⚛️", "🉑", "☢️", "☣️", "📴", "📳", "🈶", "🈚️", "🈸", "🈺",
                "🈷️", "✴️", "🆚", "💮", "🉐", "㊙️", "㊗️", "🈴", "🈵", "🈹", "🈲", "🅰️", "🅱️", "🆎",
                "🆑", "🅾️", "🆘", "❌", "⭕️", "🛑", "⛔️", "📛", "🚫", "💯", "💢", "♨️", "🚷", "🚯",
                "🚳", "🚱", "🔞", "📵", "🚭", "❗️", "❕", "❓", "❔", "‼️", "⁉️", "🔅", "🔆", "〽️",
                "⚠️", "🚸", "🔱", "⚜️", "🔰", "♻️", "✅", "🈯️", "💹", "❇️", "✳️", "❎", "🌐", "💠",
                "Ⓜ️", "🌀", "💤", "🏧", "🚾", "♿️", "🅿️", "🛗", "🈳", "🈂️", "🛂", "🛃", "🛄", "🛅",
                "🚹", "🚺", "🚼", "⚧️", "🚻", "🚮", "🎦", "📶", "🈁", "🔣", "ℹ️", "🔤", "🔡", "🔠",
                "🔢", "🔄", "🔃", "🔂", "🔁", "🔀", "▶️", "⏩", "⏭️", "⏯️", "◀️", "⏪", "⏮️", "🔼",
                "⏫", "🔽", "⏬", "⏸️", "⏹️", "⏺️", "⏏️", "📯", "🔔", "🔕", "📣", "📢", "👁️‍🗨️", "💬",
                "💭", "🗯️", "♠️", "♣️", "♥️", "♦️", "🃏", "🎴", "🀄️", "🕐", "🕑", "🕒", "🕓", "🕔",
                "🕕", "🕖", "🕗", "🕘", "🕙", "🕚", "🕛"
            ]
        ),
        StaticCategory(
            name: "旗帜",
            icon: .sfSymbol("flag", 14.5),
            emojis: [
                "🏁", "🚩", "🎌", "🏴", "🏳️", "🏳️‍🌈", "🏳️‍⚧️", "🏴‍☠️", "🇨🇳", "🇭🇰", "🇲🇴", "🇹🇼", "🇺🇸", "🇬🇧",
                "🇯🇵", "🇩🇪", "🇫🇷", "🇰🇷", "🇷🇺", "🇨🇦", "🇦🇺", "🇮🇹", "🇪🇸", "🇧🇷", "🇮🇳", "🇲🇽", "🇸🇬", "🇲🇾",
                "🇹🇭", "🇻🇳", "🇮🇩", "🇵🇭", "🇳🇱", "🇨🇭", "🇸🇪", "🇳🇴", "🇩🇰", "🇫🇮", "🇳🇿", "🇿🇦", "🇦🇷", "🇨🇱",
                "🇨🇴", "🇵🇪", "🇪🇬", "🇸🇦", "🇦🇪", "🇹🇷", "🇬🇷", "🇵🇹", "🇮🇪", "🇵🇱", "🇺🇦", "🇦🇹", "🇧🇪"
            ]
        )
    ]

    private static let filterTopics: [QuickFilterTopic] = [
        QuickFilterTopic(
            title: "开心",
            emojis: ["😂", "🤣", "😄", "😁", "😆", "😅", "😊", "☺️", "🥰", "😍", "🤩", "😘", "😋", "😜", "🤪", "🥳", "😎", "🤗", "🤭", "😏", "😌", "😉", "🙂", "🙃", "🤠", "😇", "😸", "✨", "🌟", "💫", "🎶", "🎉"]
        ),
        QuickFilterTopic(
            title: "难过",
            emojis: ["😭", "😢", "🥹", "🥺", "😔", "😞", "😓", "😩", "😫", "😖", "😣", "😥", "😰", "😨", "😱", "😒", "😑", "😐", "😶", "😮‍💨", "😪", "😴", "🤒", "🤕", "💔", "❤️‍🩹", "🫠", "😕", "😟", "🙁", "☹️", "🥀"]
        ),
        QuickFilterTopic(
            title: "爱心",
            emojis: ["❤️", "💕", "💖", "💗", "💓", "💞", "💘", "💝", "❣️", "❤️‍🔥", "❤️‍🩹", "🧡", "💛", "💚", "💙", "💜", "🤍", "🖤", "🤎", "🥰", "😍", "😘", "🫶", "💏", "🌹", "💐", "🌸", "🌺", "🌷", "💌", "💎", "✨"]
        ),
        QuickFilterTopic(
            title: "手势",
            emojis: ["👍", "👌", "✌️", "👏", "🙌", "🙏", "🤝", "🫶", "💪", "👋", "🤚", "✋", "🤙", "🤞", "🤟", "🤘", "👈", "👉", "👆", "👇", "☝️", "🫵", "✊", "👊", "🤛", "🤜", "🤌", "🤏", "🫡", "🙈", "👀", "👎"]
        ),
        QuickFilterTopic(
            title: "庆祝",
            emojis: ["🎉", "🎊", "🥳", "🎈", "🎁", "🎂", "🍰", "🥂", "🍻", "🍾", "🎆", "🎇", "✨", "🌟", "🔥", "💯", "🏆", "🥇", "🎖️", "👑", "🎀", "🪅", "🪄", "🎶", "🎤", "🎸", "💃", "🕺", "👏", "🙌", "🤩", "❤️‍🔥"]
        ),
        QuickFilterTopic(
            title: "动物",
            emojis: ["🐶", "🐱", "🐼", "🐰", "🦊", "🐻", "🐨", "🐯", "🦁", "🐮", "🐷", "🐸", "🐵", "🙈", "🐔", "🐧", "🐤", "🦆", "🦅", "🦉", "🦄", "🐝", "🦋", "🐢", "🐍", "🦖", "🐙", "🐬", "🐳", "🦈", "🐈", "🐕"]
        ),
        QuickFilterTopic(
            title: "美食",
            emojis: ["🍎", "🍉", "🍓", "🍑", "🍒", "🍇", "🍌", "🍊", "🍔", "🍟", "🍕", "🌭", "🍗", "🥩", "🍜", "🍲", "🍣", "🍱", "🥟", "🍚", "🍰", "🎂", "🧁", "🍦", "🍩", "🍫", "🍿", "☕️", "🧋", "🍺", "🍻", "🍷"]
        )
    ]

    // MARK: - UI Views

    private let topSearchRegion = UIView()
    private var topSearchTopConstraint: NSLayoutConstraint?
    private let searchPillButton = UIButton(type: .custom)
    private let searchIconView = UIImageView()
    private let searchPlaceholderLabel = UILabel()

    private let filterBarContainer = UIView()
    private let filterChipScroll = UIScrollView()
    private let filterChipStack = UIStackView()
    private let filterCancelButton = UIButton(type: .system)
    private var filterChipButtons: [UIButton] = []

    private let flowLayout = UICollectionViewFlowLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: flowLayout)

    private let bottomDock = UIView()
    private let switchButton = UIButton(type: .system)
    private let dockCategoryContainer = UIView()
    private let selectedCategoryPill = UIView()
    private let dockCategoryStack = UIStackView()
    private let backspaceButton = UIButton(type: .custom)

    private var categoryButtons: [UIButton] = []
    private var selectedCategoryIndex: Int = 0
    private var recentEmojis: [String] = LokeyRecentEmojis.load()
    private var hasLoadedInitialSections = false
    private var activeFilterIndex: Int? = nil
    private var isProgrammaticScroll = false

    private var cachedLeftInset: CGFloat = 11.5
    private var cachedRightInset: CGFloat = 3.5
    private var cachedInterSectionGap: CGFloat = 10.0

    // Accelerated backspace timers
    private var backspaceDelayTimer: Timer?
    private var backspaceRepeatTimer: Timer?

    private static let deleteNormalImage = UIImage(
        systemName: "delete.left",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 18.5, weight: .regular)
    )
    private static let deleteFilledImage = UIImage(
        systemName: "delete.left.fill",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 18.5, weight: .regular)
    )

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = KeyboardTheme.hitTestableClearBacking
        setupViews()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopBackspaceTimers()
    }

    /// Refreshes the persistent `常用` category when the Emoji panel is presented so recently tapped
    /// emojis appear first without shifting cells mid-tap during rapid multi-emoji entry.
    func prepareForDisplay() {
        let latestRecents = LokeyRecentEmojis.load()
        let recentsChanged = (latestRecents != recentEmojis)
        recentEmojis = latestRecents
        if activeFilterIndex != nil {
            exitFilterMode(animated: false)
            hasLoadedInitialSections = true
        } else {
            let expectedSections = 1 + Self.staticCategories.count
            if !hasLoadedInitialSections || collectionView.numberOfSections != expectedSections {
                collectionView.reloadData()
                hasLoadedInitialSections = true
            } else if recentsChanged {
                UIView.performWithoutAnimation {
                    collectionView.reloadSections(IndexSet(integer: 0))
                }
            }
            updateSelectedCategory(index: 0, animated: false)
            if collectionView.numberOfSections > 0 && collectionView.numberOfItems(inSection: 0) > 0 {
                collectionView.setContentOffset(.zero, animated: false)
            }
        }
    }

    // MARK: - Setup

    private func setupViews() {
        // 1. Top Search Capsule (`top = 7.0pt` portrait / `3.5pt` landscape, `height = 35.0pt`, `leading/trailing = 9.5pt`, `cornerRadius = 17.5pt`)
        // Built directly inside `EmojiKeyboardView` bounds without overflowing above `topAnchor`.
        topSearchRegion.translatesAutoresizingMaskIntoConstraints = false
        topSearchRegion.backgroundColor = .clear
        addSubview(topSearchRegion)

        searchPillButton.translatesAutoresizingMaskIntoConstraints = false
        searchPillButton.layer.cornerRadius = 17.5
        searchPillButton.layer.cornerCurve = .continuous
        searchPillButton.addTarget(self, action: #selector(handleSearchPillTap), for: .touchUpInside)
        topSearchRegion.addSubview(searchPillButton)

        searchIconView.translatesAutoresizingMaskIntoConstraints = false
        searchIconView.contentMode = .scaleAspectFit
        searchIconView.image = UIImage(
            systemName: "magnifyingglass",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15.5, weight: .regular)
        )
        searchIconView.isUserInteractionEnabled = false
        searchPillButton.addSubview(searchIconView)

        searchPlaceholderLabel.translatesAutoresizingMaskIntoConstraints = false
        searchPlaceholderLabel.text = "搜索表情符号"
        searchPlaceholderLabel.font = .systemFont(ofSize: 17.0, weight: .regular)
        searchPlaceholderLabel.isUserInteractionEnabled = false
        searchPillButton.addSubview(searchPlaceholderLabel)

        // Inline offline quick-filter bar (shown when user taps `搜索表情符号`)
        filterBarContainer.translatesAutoresizingMaskIntoConstraints = false
        filterBarContainer.isHidden = true
        topSearchRegion.addSubview(filterBarContainer)

        filterCancelButton.translatesAutoresizingMaskIntoConstraints = false
        filterCancelButton.setTitle("取消", for: .normal)
        filterCancelButton.titleLabel?.font = .systemFont(ofSize: 15.5, weight: .regular)
        filterCancelButton.addTarget(self, action: #selector(handleCancelFilterTap), for: .touchUpInside)
        filterBarContainer.addSubview(filterCancelButton)

        filterChipScroll.translatesAutoresizingMaskIntoConstraints = false
        filterChipScroll.showsHorizontalScrollIndicator = false
        filterChipScroll.showsVerticalScrollIndicator = false
        filterChipScroll.alwaysBounceHorizontal = true
        filterChipScroll.alwaysBounceVertical = false
        KeyboardTheme.disableScrollEdgeEffects(on: filterChipScroll)
        filterBarContainer.addSubview(filterChipScroll)

        filterChipStack.translatesAutoresizingMaskIntoConstraints = false
        filterChipStack.axis = .horizontal
        filterChipStack.alignment = .center
        filterChipStack.spacing = 6.0
        filterChipScroll.addSubview(filterChipStack)

        for (idx, topic) in Self.filterTopics.enumerated() {
            let chip = UIButton(type: .custom)
            chip.tag = idx
            chip.setTitle(topic.title, for: .normal)
            chip.titleLabel?.font = .systemFont(ofSize: 14.0, weight: .medium)
            chip.contentEdgeInsets = UIEdgeInsets(top: 5, left: 11, bottom: 5, right: 11)
            chip.layer.cornerRadius = 13.5
            chip.layer.cornerCurve = .continuous
            chip.addTarget(self, action: #selector(handleFilterChipTap(_:)), for: .touchUpInside)
            filterChipStack.addArrangedSubview(chip)
            filterChipButtons.append(chip)
        }

        // 2. Horizontal 4-Row × 8-Column Emoji CollectionView
        flowLayout.scrollDirection = .horizontal
        flowLayout.minimumInteritemSpacing = 0
        flowLayout.minimumLineSpacing = 0
        flowLayout.headerReferenceSize = .zero

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.alwaysBounceHorizontal = true
        collectionView.alwaysBounceVertical = false
        collectionView.decelerationRate = .normal
        KeyboardTheme.disableScrollEdgeEffects(on: collectionView)
        collectionView.register(EmojiCell.self, forCellWithReuseIdentifier: EmojiCell.identifier)
        addSubview(collectionView)

        // 3. Bottom Dock (`拼音` + 9 Outline Category Icons + Selected Circle Pill + Borderless `⌫`)
        bottomDock.translatesAutoresizingMaskIntoConstraints = false
        bottomDock.backgroundColor = .clear
        addSubview(bottomDock)

        switchButton.translatesAutoresizingMaskIntoConstraints = false
        switchButton.setTitle(switchButtonTitle, for: .normal)
        switchButton.titleLabel?.font = .systemFont(ofSize: 15.0, weight: .regular)
        switchButton.backgroundColor = .clear
        switchButton.addTarget(self, action: #selector(handleSwitchTap), for: .touchUpInside)
        bottomDock.addSubview(switchButton)

        backspaceButton.translatesAutoresizingMaskIntoConstraints = false
        backspaceButton.backgroundColor = .clear
        backspaceButton.setImage(Self.deleteNormalImage, for: .normal)
        backspaceButton.addTarget(self, action: #selector(handleBackspaceDown), for: .touchDown)
        backspaceButton.addTarget(self, action: #selector(handleBackspaceUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        bottomDock.addSubview(backspaceButton)

        dockCategoryContainer.translatesAutoresizingMaskIntoConstraints = false
        dockCategoryContainer.backgroundColor = .clear
        bottomDock.addSubview(dockCategoryContainer)

        selectedCategoryPill.frame = CGRect(x: 0, y: 0, width: 29.5, height: 29.5)
        selectedCategoryPill.layer.cornerRadius = 14.75
        selectedCategoryPill.isUserInteractionEnabled = false
        dockCategoryContainer.addSubview(selectedCategoryPill)

        dockCategoryStack.translatesAutoresizingMaskIntoConstraints = false
        dockCategoryStack.axis = .horizontal
        dockCategoryStack.distribution = .fillEqually
        dockCategoryStack.alignment = .fill
        dockCategoryStack.spacing = 0
        dockCategoryContainer.addSubview(dockCategoryStack)

        // Build all 9 category buttons (`常用` at index 0 + 8 static categories)
        let totalCategories = 1 + Self.staticCategories.count
        for idx in 0..<totalCategories {
            let btn = UIButton(type: .system)
            btn.tag = idx
            btn.backgroundColor = .clear
            let img: UIImage?
            if idx == 0 {
                img = KeyboardTheme.nativeEmojiClockIcon(pointSize: 17.5)
            } else {
                switch Self.staticCategories[idx - 1].icon {
                case let .custom(builder):
                    img = builder()
                case let .sfSymbol(symName, pt):
                    let weight: UIImage.SymbolWeight = (symName == "heart") ? .medium : .regular
                    let cfg = UIImage.SymbolConfiguration(pointSize: pt, weight: weight)
                    img = UIImage(systemName: symName, withConfiguration: cfg)
                }
            }
            btn.setImage(img, for: .normal)
            btn.addTarget(self, action: #selector(handleCategoryTap(_:)), for: .touchUpInside)
            dockCategoryStack.addArrangedSubview(btn)
            categoryButtons.append(btn)
        }

        let searchTopConstraint = topSearchRegion.topAnchor.constraint(equalTo: topAnchor, constant: 7.0)
        topSearchTopConstraint = searchTopConstraint

        NSLayoutConstraint.activate([
            topSearchRegion.leadingAnchor.constraint(equalTo: leadingAnchor),
            topSearchRegion.trailingAnchor.constraint(equalTo: trailingAnchor),
            searchTopConstraint,
            topSearchRegion.heightAnchor.constraint(equalToConstant: 35.0),

            searchPillButton.leadingAnchor.constraint(equalTo: topSearchRegion.leadingAnchor, constant: 9.5),
            searchPillButton.trailingAnchor.constraint(equalTo: topSearchRegion.trailingAnchor, constant: -9.5),
            searchPillButton.topAnchor.constraint(equalTo: topSearchRegion.topAnchor),
            searchPillButton.bottomAnchor.constraint(equalTo: topSearchRegion.bottomAnchor),

            searchIconView.leadingAnchor.constraint(equalTo: searchPillButton.leadingAnchor, constant: 12.5),
            searchIconView.centerYAnchor.constraint(equalTo: searchPillButton.centerYAnchor),
            searchIconView.widthAnchor.constraint(equalToConstant: 17.5),
            searchIconView.heightAnchor.constraint(equalToConstant: 17.5),

            searchPlaceholderLabel.leadingAnchor.constraint(equalTo: searchIconView.trailingAnchor, constant: 7.5),
            searchPlaceholderLabel.centerYAnchor.constraint(equalTo: searchPillButton.centerYAnchor),
            searchPlaceholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: searchPillButton.trailingAnchor, constant: -12.0),

            filterBarContainer.leadingAnchor.constraint(equalTo: topSearchRegion.leadingAnchor, constant: 9.5),
            filterBarContainer.trailingAnchor.constraint(equalTo: topSearchRegion.trailingAnchor, constant: -9.5),
            filterBarContainer.topAnchor.constraint(equalTo: topSearchRegion.topAnchor),
            filterBarContainer.bottomAnchor.constraint(equalTo: topSearchRegion.bottomAnchor),

            filterCancelButton.trailingAnchor.constraint(equalTo: filterBarContainer.trailingAnchor, constant: -2.0),
            filterCancelButton.centerYAnchor.constraint(equalTo: filterBarContainer.centerYAnchor),
            filterCancelButton.widthAnchor.constraint(equalToConstant: 42.0),

            filterChipScroll.leadingAnchor.constraint(equalTo: filterBarContainer.leadingAnchor),
            filterChipScroll.trailingAnchor.constraint(equalTo: filterCancelButton.leadingAnchor, constant: -6.0),
            filterChipScroll.topAnchor.constraint(equalTo: filterBarContainer.topAnchor),
            filterChipScroll.bottomAnchor.constraint(equalTo: filterBarContainer.bottomAnchor),

            filterChipStack.leadingAnchor.constraint(equalTo: filterChipScroll.contentLayoutGuide.leadingAnchor),
            filterChipStack.trailingAnchor.constraint(equalTo: filterChipScroll.contentLayoutGuide.trailingAnchor),
            filterChipStack.topAnchor.constraint(equalTo: filterChipScroll.frameLayoutGuide.topAnchor),
            filterChipStack.bottomAnchor.constraint(equalTo: filterChipScroll.frameLayoutGuide.bottomAnchor),
            filterChipStack.heightAnchor.constraint(equalTo: filterChipScroll.frameLayoutGuide.heightAnchor),

            bottomDock.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomDock.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomDock.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1.0),
            bottomDock.heightAnchor.constraint(equalToConstant: 32.0),

            // Symmetric dock geometry: switchButton trailing (53.5pt) & backspaceButton leading (w - 53.5pt)
            // center the 9-icon dock stack at exact `63.0pt .. w - 63.0pt` (`Cat 0 = 80.4pt, Cat 8 = 359.6pt` on `440pt`)!
            switchButton.leadingAnchor.constraint(equalTo: bottomDock.leadingAnchor, constant: 7.5),
            switchButton.centerYAnchor.constraint(equalTo: bottomDock.centerYAnchor),
            switchButton.widthAnchor.constraint(equalToConstant: 46.0),
            switchButton.heightAnchor.constraint(equalToConstant: 32.0),

            backspaceButton.trailingAnchor.constraint(equalTo: bottomDock.trailingAnchor, constant: -10.5),
            backspaceButton.centerYAnchor.constraint(equalTo: bottomDock.centerYAnchor),
            backspaceButton.widthAnchor.constraint(equalToConstant: 43.0),
            backspaceButton.heightAnchor.constraint(equalToConstant: 32.0),

            dockCategoryContainer.leadingAnchor.constraint(equalTo: switchButton.trailingAnchor, constant: 9.5),
            dockCategoryContainer.trailingAnchor.constraint(equalTo: backspaceButton.leadingAnchor, constant: -9.5),
            dockCategoryContainer.topAnchor.constraint(equalTo: bottomDock.topAnchor),
            dockCategoryContainer.bottomAnchor.constraint(equalTo: bottomDock.bottomAnchor),

            dockCategoryStack.leadingAnchor.constraint(equalTo: dockCategoryContainer.leadingAnchor),
            dockCategoryStack.trailingAnchor.constraint(equalTo: dockCategoryContainer.trailingAnchor),
            dockCategoryStack.topAnchor.constraint(equalTo: dockCategoryContainer.topAnchor),
            dockCategoryStack.bottomAnchor.constraint(equalTo: dockCategoryContainer.bottomAnchor),

            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topSearchRegion.bottomAnchor, constant: 3.5),
            collectionView.bottomAnchor.constraint(equalTo: bottomDock.topAnchor, constant: -3.0),
        ])
    }

    override func layoutSubviews() {
        let targetTop: CGFloat = (bounds.width > 520.0) ? 3.5 : 7.0
        if let topConstraint = topSearchTopConstraint, topConstraint.constant != targetTop {
            topConstraint.constant = targetTop
        }
        super.layoutSubviews()
        let w = collectionView.bounds.width
        let h = collectionView.bounds.height
        guard w > 100 && h > 60 else { return }

        // Exact 4 rows × 8 columns in portrait (3 rows × 11 columns in compact landscape)
        let rows: CGFloat = (h < 160.0) ? 3.0 : 4.0
        let cols: CGFloat = (w > 520.0) ? 11.0 : 8.0
        let leftInset: CGFloat = 11.5
        let rightInset: CGFloat = 3.5
        let vInset: CGFloat = 1.0

        let availW = w - leftInset - rightInset
        let cellW = min(46.0, floor((availW / cols) * 3.0) / 3.0)
        let cellH = max(36.0, floor(((h - vInset * 2.0) / rows) * 3.0) / 3.0)
        let lineSpacing = max(0.0, (availW - cellW * cols) / max(1.0, cols - 1.0))

        cachedLeftInset = leftInset
        cachedRightInset = rightInset
        cachedInterSectionGap = 10.0

        let targetSize = CGSize(width: cellW, height: cellH)
        if flowLayout.itemSize != targetSize || abs(flowLayout.minimumLineSpacing - lineSpacing) > 0.05 {
            flowLayout.itemSize = targetSize
            flowLayout.minimumLineSpacing = lineSpacing
            flowLayout.minimumInteritemSpacing = 0
            flowLayout.invalidateLayout()
        }

        positionSelectedCategoryPill(animated: false)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            KeyboardTheme.disableScrollEdgeEffects(on: filterChipScroll)
            KeyboardTheme.disableScrollEdgeEffects(on: collectionView)
            applyTheme()
        } else {
            cancelActiveInteractions()
        }
    }

    func cancelActiveInteractions() {
        LokeyDiagnosticLogger.shared.setScrollInteractionActive(false, owner: self)
        stopBackspaceTimers()
        backspaceButton.setImage(Self.deleteNormalImage, for: .normal)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            applyTheme()
        }
    }

    // MARK: - Theme & Category Selection

    private func applyTheme() {
        let dark = traitCollection.userInterfaceStyle == .dark

        searchPillButton.backgroundColor = KeyboardTheme.emojiSearchBarFill(dark: dark)
        let placeholderColor = KeyboardTheme.emojiSearchBarPlaceholderColor(dark: dark)
        searchIconView.tintColor = placeholderColor
        searchPlaceholderLabel.textColor = placeholderColor

        filterCancelButton.setTitleColor(KeyboardTheme.dynamicPrimaryText, for: .normal)
        updateFilterChipAppearances(dark: dark)

        // Native iOS 26 Emoji bottom dock: pure transparent `.clear` backgrounds on `拼音` and `⌫`
        switchButton.backgroundColor = .clear
        switchButton.setTitleColor(KeyboardTheme.dynamicPrimaryText, for: .normal)

        backspaceButton.backgroundColor = .clear
        backspaceButton.tintColor = KeyboardTheme.dynamicPrimaryText

        selectedCategoryPill.backgroundColor = KeyboardTheme.emojiCategoryPillFill(dark: dark)
        updateCategoryButtonColors(dark: dark)
    }

    private func updateFilterChipAppearances(dark: Bool) {
        for (idx, chip) in filterChipButtons.enumerated() {
            let selected = (activeFilterIndex == idx)
            if selected {
                chip.backgroundColor = KeyboardTheme.candidateHighlightPillFill(dark: dark)
                chip.setTitleColor(dark ? .white : .black, for: .normal)
            } else {
                chip.backgroundColor = KeyboardTheme.emojiSearchBarFill(dark: dark)
                chip.setTitleColor(KeyboardTheme.dynamicSecondaryText, for: .normal)
            }
        }
    }

    private func updateCategoryButtonColors(dark: Bool) {
        selectedCategoryPill.isHidden = (activeFilterIndex != nil)
        for (idx, btn) in categoryButtons.enumerated() {
            let isSelected = (activeFilterIndex == nil && idx == selectedCategoryIndex)
            btn.tintColor = KeyboardTheme.emojiCategoryIconTint(dark: dark, selected: isSelected)
        }
    }

    private func positionSelectedCategoryPill(animated: Bool) {
        let count = categoryButtons.count
        guard count > 0, selectedCategoryIndex >= 0 && selectedCategoryIndex < count else { return }
        let containerW = dockCategoryContainer.bounds.width > 0
            ? dockCategoryContainer.bounds.width
            : max(0.0, bounds.width - 126.0)
        let containerH = dockCategoryContainer.bounds.height > 0
            ? dockCategoryContainer.bounds.height
            : 32.0
        guard containerW > 30.0 else { return }

        let slotW = containerW / CGFloat(count)
        let centerX = (CGFloat(selectedCategoryIndex) + 0.5) * slotW

        let pillDiameter: CGFloat = 29.5
        let targetFrame = CGRect(
            x: centerX - pillDiameter * 0.5,
            y: (containerH - pillDiameter) * 0.5,
            width: pillDiameter,
            height: pillDiameter
        )
        if animated {
            UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                self.selectedCategoryPill.frame = targetFrame
            }
        } else {
            selectedCategoryPill.frame = targetFrame
        }
    }

    // MARK: - Helpers

    private func updateSelectedCategory(index: Int, animated: Bool) {
        guard index >= 0 && index < categoryButtons.count else { return }
        let changed = (selectedCategoryIndex != index)
        selectedCategoryIndex = index
        let dark = traitCollection.userInterfaceStyle == .dark
        updateCategoryButtonColors(dark: dark)
        if changed || !animated {
            positionSelectedCategoryPill(animated: animated)
        }
    }

    private func emojisForSection(_ section: Int) -> [String] {
        if let filterIdx = activeFilterIndex {
            return Self.filterTopics[filterIdx].emojis
        }
        if section == 0 {
            return recentEmojis
        }
        return Self.staticCategories[section - 1].emojis
    }

    // MARK: - UICollectionViewDataSource & DelegateFlowLayout

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        if activeFilterIndex != nil {
            return 1
        }
        return 1 + Self.staticCategories.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        emojisForSection(section).count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: EmojiCell.identifier,
            for: indexPath
        ) as? EmojiCell else {
            return UICollectionViewCell()
        }
        let list = emojisForSection(indexPath.section)
        if indexPath.item < list.count {
            cell.configure(emoji: list[indexPath.item])
        }
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        insetForSectionAt section: Int
    ) -> UIEdgeInsets {
        let totalSecs = numberOfSections(in: collectionView)
        let left = (section == 0) ? cachedLeftInset : cachedInterSectionGap
        let right = (section == totalSecs - 1) ? cachedRightInset : cachedInterSectionGap
        return UIEdgeInsets(top: 1.0, left: left, bottom: 1.0, right: right)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let list = emojisForSection(indexPath.section)
        guard indexPath.item < list.count else { return }
        let emoji = list[indexPath.item]
        if !LokeyDiagnosticLogger.shared.isSecureContext { LokeyRecentEmojis.recordUsage(emoji) }
        onInsertEmoji?(emoji)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === collectionView, activeFilterIndex == nil, !isProgrammaticScroll else { return }
        let probeX = collectionView.contentOffset.x + collectionView.bounds.width * 0.28
        let probeY = collectionView.bounds.height * 0.35
        if let indexPath = collectionView.indexPathForItem(at: CGPoint(x: max(12, probeX), y: probeY)),
           indexPath.section != selectedCategoryIndex {
            updateSelectedCategory(index: indexPath.section, animated: true)
        }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if scrollView === collectionView {
            isProgrammaticScroll = false
        }
        LokeyDiagnosticLogger.shared.setScrollInteractionActive(false, owner: self)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if scrollView === collectionView {
            isProgrammaticScroll = false
        }
        LokeyDiagnosticLogger.shared.setScrollInteractionActive(true, owner: self)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            LokeyDiagnosticLogger.shared.setScrollInteractionActive(false, owner: self)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        LokeyDiagnosticLogger.shared.setScrollInteractionActive(false, owner: self)
    }

    // MARK: - Actions

    @objc private func handleSearchPillTap() {
        activeFilterIndex = 0
        searchPillButton.isHidden = true
        filterBarContainer.isHidden = false
        let dark = traitCollection.userInterfaceStyle == .dark
        updateFilterChipAppearances(dark: dark)
        updateCategoryButtonColors(dark: dark)
        collectionView.reloadData()
        collectionView.setContentOffset(.zero, animated: false)
    }

    @objc private func handleFilterChipTap(_ sender: UIButton) {
        let idx = sender.tag
        guard idx >= 0 && idx < Self.filterTopics.count else { return }
        activeFilterIndex = idx
        let dark = traitCollection.userInterfaceStyle == .dark
        updateFilterChipAppearances(dark: dark)
        collectionView.reloadData()
        collectionView.setContentOffset(.zero, animated: false)
    }

    @objc private func handleCancelFilterTap() {
        exitFilterMode(animated: true)
    }

    private func exitFilterMode(animated: Bool) {
        activeFilterIndex = nil
        filterBarContainer.isHidden = true
        searchPillButton.isHidden = false
        recentEmojis = LokeyRecentEmojis.load()
        collectionView.reloadData()
        updateSelectedCategory(index: selectedCategoryIndex, animated: animated)
        let sec = min(selectedCategoryIndex, max(0, numberOfSections(in: collectionView) - 1))
        if collectionView.numberOfItems(inSection: sec) > 0 {
            collectionView.scrollToItem(at: IndexPath(item: 0, section: sec), at: .left, animated: false)
        }
    }

    @objc private func handleSwitchTap() {
        onSwitchToKeyboard?()
    }

    @objc private func handleCategoryTap(_ sender: UIButton) {
        let sec = sender.tag
        if activeFilterIndex != nil {
            activeFilterIndex = nil
            filterBarContainer.isHidden = true
            searchPillButton.isHidden = false
            recentEmojis = LokeyRecentEmojis.load()
            collectionView.reloadData()
        }
        guard sec >= 0 && sec < numberOfSections(in: collectionView),
              collectionView.numberOfItems(inSection: sec) > 0 else { return }
        updateSelectedCategory(index: sec, animated: true)
        isProgrammaticScroll = true
        if sec == 0 {
            collectionView.setContentOffset(.zero, animated: true)
        } else {
            let targetIndexPath = IndexPath(item: 0, section: sec)
            collectionView.scrollToItem(at: targetIndexPath, at: .left, animated: true)
        }
    }

    @objc private func handleBackspaceDown() {
        backspaceButton.setImage(Self.deleteFilledImage, for: .normal)
        onBackspace?()
        stopBackspaceTimers()
        backspaceDelayTimer = Timer.scheduledTimer(withTimeInterval: 0.38, repeats: false) { [weak self] _ in
            self?.startRepeatingBackspace()
        }
    }

    private func startRepeatingBackspace() {
        backspaceRepeatTimer = Timer.scheduledTimer(withTimeInterval: 0.075, repeats: true) { [weak self] _ in
            self?.onBackspace?()
        }
    }

    @objc private func handleBackspaceUp() {
        backspaceButton.setImage(Self.deleteNormalImage, for: .normal)
        stopBackspaceTimers()
    }

    private func stopBackspaceTimers() {
        backspaceDelayTimer?.invalidate()
        backspaceDelayTimer = nil
        backspaceRepeatTimer?.invalidate()
        backspaceRepeatTimer = nil
    }
}

// MARK: - Emoji Cell

private final class EmojiCell: UICollectionViewCell {
    static let identifier = "EmojiCell"
    private let emojiLabel = UILabel()

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.08, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.emojiLabel.transform = self.isHighlighted
                    ? CGAffineTransform(scaleX: 1.15, y: 1.15)
                    : .identity
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        emojiLabel.frame = contentView.bounds
        emojiLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        emojiLabel.textAlignment = .center
        emojiLabel.font = .systemFont(ofSize: 36.0)
        contentView.addSubview(emojiLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(emoji: String) {
        emojiLabel.text = emoji
    }
}
