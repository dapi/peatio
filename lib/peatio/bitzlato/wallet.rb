require 'digest'

module Bitzlato
  class Wallet < Peatio::Wallet::Abstract
    class WithdrawInfo
      attr_accessor :is_done, :id, :currency, :amount
    end
    def initialize(features = {})
      @features = features
      @settings = {}
    end

    def configure(settings = {})
      # Clean client state during configure.
      @client = nil

      @settings = settings

      @wallet = @settings.fetch(:wallet) do
        raise Peatio::Wallet::MissingSettingError, :wallet
      end.slice(:uri, :key, :uid, :withdraw_polling_methods)

      @currency = @settings.fetch(:currency) do
       raise Peatio::Wallet::MissingSettingError, :currency
      end.slice(:id)
    end

    def create_transaction!(transaction, options = {})
      voucher = client.post(
        '/api/p2p/vouchers/',
        {'cryptocurrency': transaction.currency_id.upcase, 'amount': transaction.amount, 'method':'crypto','currency': 'USD'}
      )

      transaction.options = transaction
        .options
        .merge(
          'voucher' => voucher,
          'links' => voucher['links'].map { |link| { 'title' => link['type'], 'url' => link['url'] } }
      )

      transaction.txout = voucher['deepLinkCode']
      transaction.hash = voucher['deepLinkCode']
      transaction
    rescue Bitzlato::Client::Error => e
      raise Peatio::Wallet::ClientError, e
    end

    def load_balance!
      # TODO fetch actual balance
      999_999_999 # Yeah!
    end

    def create_deposit_intention!(account_id: , amount: )
      response = client
        .post('/api/gate/v1/invoices/', {
        cryptocurrency: currency_id.to_s.upcase,
        amount: amount,
        comment: "Exchange service deposit for account #{account_id}"
        })

      {
        amount: response['amount'].to_d,
        username: response['username'],
        id: response['id'],
        links: response['link'].each_with_object([]) { |e, a| a << { 'title' => e.first, 'url' => e.second } },
        expires_at: Time.at(response['expiryAt']/1000)
      }
    end

    def poll_deposits
      client
        .get('/api/gate/v1/invoices/transactions/')['data']
        .map do |transaction|
        {
          id: transaction['invoiceId'],
          amount: transaction['amount'].to_d,
          cryptocurrency: transaction['cryptocurrency']
        }
      end
    end

    def poll_withdraws
      if @wallet[:withdraw_polling_methods].blank?
        Rails.logger.error("No withdraw_polling_methods key in settings for bitzlato wallet")
        return
      end

      withdraws = []

      @wallet[:withdraw_polling_methods].each do |method|
        case method
        when 'vouchers'
          withdraws += poll_vouchers
        when 'payments'
          withdraws += poll_payments
        else
          Rails.logger.error("Unknown withdraw_polling_methods (#{method})")
          next
        end
      end

      withdraws
    end

    private

    def poll_payments
      client
        .get('/api/gate/v1/payments/list/')
        .map do |payment|
        WithdrawInfo.new.tap do |w|
          w.id = Digest::MD5.hexdigest payment.slice('publicName', 'amount', 'cryptocurrency', 'date').values.map(&:to_s).sort.join
          w.is_done = payment['status'] == 'done'
          w.amount = payment['amount'].to_d
          w.currency = payment['cryptocurrency']
        end
      end
    end

    def poll_vouchers
      client
        .get('/api/p2p/vouchers/')['data']
        .map do |voucher|
        WithdrawInfo.new.tap do |w|
          w.id = voucher['deepLinkCode']
          w.is_done = voucher['status'] == 'cashed'
          w.amount = voucher.dig('cryptocurrency', 'amount').to_d
          w.currency = voucher.dig('cryptocurrency', 'code').downcase
        end
      end
    end

    def currency_id
      @currency.fetch(:id)
    end

    def client
      @client ||= Bitzlato::Client
        .new(home_url: ENV.fetch('BITZLATO_API_URL', @wallet.fetch(:uri)),
             key: ENV.fetch('BITZLATO_API_KEY', @wallet.fetch(:key)).yield_self { |key| key.is_a?(String) ? JSON.parse(key) : key },
             uid: ENV.fetch('BITZLATO_API_CLIENT_UID', @wallet.fetch(:uid)).to_i,
             logger: Rails.env.development?)
    end
  end
end
