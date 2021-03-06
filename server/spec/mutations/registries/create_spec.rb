
describe Registries::Create do
  let(:user) { User.create!(email: 'joe@domain.com')}

  let(:grid) {
    grid = Grid.create!(name: 'test-grid')
    grid.users << user
    grid
  }

  describe '#run' do
    it 'requires grid' do
      outcome = described_class.new(
        username: 'john',
        password: 'password',
        email: 'john@example.org',
        url: 'https://registry.example.org'
      ).run
      expect(outcome.errors[:grid]).not_to be_nil
    end

    it 'requires username' do
      outcome = described_class.new(
        grid: grid,
        password: 'password',
        email: 'john@example.org',
        url: 'https://registry.example.org'
      ).run
      expect(outcome.errors[:username]).not_to be_nil
    end

    it 'requires password' do
      outcome = described_class.new(
        grid: grid,
        username: 'john',
        email: 'john@example.org',
        url: 'https://registry.example.org'
      ).run
      expect(outcome.errors[:password]).not_to be_nil
    end

    it 'does not require email' do
      expect {
        described_class.new(
          grid: grid,
          username: 'john',
          password: 'password',
          url: 'https://registry.example.org'
        ).run
      }.to change { Registry.count }.by(1)
    end

    it 'requires url' do
      outcome = described_class.new(
        grid: grid,
        username: 'john',
        password: 'password',
        email: 'john@example.org'
      ).run
      expect(outcome.errors[:url]).not_to be_nil
    end

    it 'rejects invalid url format' do
      outcome = described_class.new(
        grid: grid,
        username: 'john',
        password: 'password',
        email: 'john@example.org',
        url: 'example.org',
      ).run
      expect(outcome).to_not be_success
      expect(outcome.errors.message).to eq 'url' => "Url isn't in the right format"
    end

    it 'rejects invalid multi-line url ' do
      outcome = described_class.new(
        grid: grid,
        username: 'john',
        password: 'password',
        email: 'john@example.org',
        url: "foo\nhttps://registry.example.org",
      ).run
      expect(outcome).to_not be_success
      expect(outcome.errors.message).to eq 'url' => "Url isn't in the right format"
    end

    it 'creates a new grid registry' do
      expect {
        described_class.new(
          grid: grid,
          username: 'john',
          password: 'password',
          email: 'john@example.org',
          url: 'https://registry.example.org'
        ).run
      }.to change{ Registry.count }.by(1)
    end
  end
end
