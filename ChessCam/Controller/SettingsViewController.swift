import UIKit

final class SettingsViewController: UITableViewController {
    var onSave: ((AppSettings) -> Void)?

    private var settings: AppSettings
    private let green = UIColor(red: 0.29, green: 0.49, blue: 0.30, alpha: 1)
    private let site = UISegmentedControl(items: ChessSite.allCases.map(\.title))
    private let split = UISlider()
    private let splitValue = UILabel()
    private let mirror = UISwitch()
    private let photos = UISwitch()

    init(settings: AppSettings) {
        self.settings = settings
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("Programmatic UI")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Настройки"
        navigationItem.hidesBackButton = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Готово", style: .prominent, target: self, action: #selector(save)
        )
        navigationItem.rightBarButtonItem?.tintColor = green
        tableView.backgroundColor = UIColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)

        site.selectedSegmentIndex = ChessSite.allCases.firstIndex(of: settings.site) ?? 0
        site.selectedSegmentTintColor = green
        site.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)

        split.minimumValue = 0.2
        split.maximumValue = 0.8
        split.value = Float(settings.boardFraction)
        split.minimumTrackTintColor = green
        split.addTarget(self, action: #selector(splitChanged), for: .valueChanged)
        splitValue.font = .systemFont(ofSize: 16, weight: .semibold)
        splitChanged()

        mirror.isOn = settings.mirrorCamera
        mirror.onTintColor = green
        photos.isOn = settings.saveToPhotos
        photos.onTintColor = green
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 2 ? 2 : 1
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        switch indexPath.section {
        case 0: return 108
        case 1: return 112
        default: return 58
        }
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 16 }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? { UIView() }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch indexPath.section {
        case 0: return siteCell()
        case 1: return splitCell()
        default:
            return optionCell(
                title: indexPath.row == 0 ? "Зеркальная камера" : "Сохранять в Фото",
                symbol: indexPath.row == 0 ? "camera" : "photo.on.rectangle",
                control: indexPath.row == 0 ? mirror : photos
            )
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 2 ? "Видео остаются в приложении." : nil
    }

    private func siteCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        let title = UILabel()
        title.text = "Сайт"
        title.font = .systemFont(ofSize: 16)
        let stack = UIStackView(arrangedSubviews: [title, site])
        stack.axis = .vertical
        stack.spacing = 12
        add(stack, to: cell)
        site.heightAnchor.constraint(equalToConstant: 42).isActive = true
        return cell
    }

    private func splitCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        let title = UILabel()
        title.text = "Доля сайта"
        title.font = .systemFont(ofSize: 16)
        let heading = UIStackView(arrangedSubviews: [title, UIView(), splitValue])
        heading.alignment = .center

        let minimum = limitLabel("20%")
        let maximum = limitLabel("80%")
        let sliderRow = UIStackView(arrangedSubviews: [minimum, split, maximum])
        sliderRow.alignment = .center
        sliderRow.spacing = 12

        let stack = UIStackView(arrangedSubviews: [heading, sliderRow])
        stack.axis = .vertical
        stack.spacing = 16
        add(stack, to: cell)
        return cell
    }

    private func optionCell(title: String, symbol: String, control: UISwitch) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.textLabel?.text = title
        cell.textLabel?.font = .systemFont(ofSize: 16)
        cell.imageView?.image = UIImage(systemName: symbol)
        cell.imageView?.tintColor = .label
        cell.accessoryView = control
        return cell
    }

    private func add(_ stack: UIStackView, to cell: UITableViewCell) {
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -18),
            stack.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor)
        ])
    }

    private func limitLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        return label
    }

    @objc private func splitChanged() {
        splitValue.text = "\(Int((split.value * 100).rounded()))%"
    }

    @objc private func save() {
        settings.site = ChessSite.allCases[site.selectedSegmentIndex]
        settings.boardFraction = Double(split.value)
        settings.mirrorCamera = mirror.isOn
        settings.saveToPhotos = photos.isOn
        onSave?(settings)
        navigationController?.popViewController(animated: true)
    }
}
