# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Instagram::SendCommentReplyService do
  let(:ig_id) { "1784#{SecureRandom.random_number(10**10)}" }

  let(:channel) do
    ch = Channel::Instagram.new(instagram_id: ig_id, access_token: 'token')
    ch.save!(validate: false)
    ch
  end

  let!(:inbox) { Inbox.create!(channel: channel, name: "IG #{SecureRandom.hex(3)}") }

  before do
    allow(MetaBaseUrl).to receive(:enabled?).and_return(true)
    allow(MetaBaseUrl).to receive(:for).with(:instagram).and_return('https://graph.instagram.com/v23.0')
    Instagram::CommentCreator.new(
      ig_account_id: ig_id,
      value: { 'from' => { 'id' => '111', 'username' => 'cliente' }, 'id' => 'c1', 'text' => 'Qual o valor' }
    ).perform
  end

  let(:conversation) { Conversation.order(:created_at).last }

  def reply(content_attributes = {})
    conversation.messages.create!(
      inbox_id: inbox.id, message_type: :outgoing, content: 'R$ 50', content_attributes: content_attributes
    )
  end

  def ok_response(body)
    instance_double(HTTParty::Response, success?: true, parsed_response: body)
  end

  it 'replies publicly to the latest customer comment by default' do
    message = reply
    expect(HTTParty).to receive(:post)
      .with('https://graph.instagram.com/v23.0/c1/replies', hash_including(body: { message: 'R$ 50' }))
      .and_return(ok_response('id' => 'reply-1'))

    described_class.new(message: message).perform

    expect(message.reload.source_id).to eq('reply-1')
  end

  it 'sends a private reply (DM) when requested' do
    message = reply('instagram_reply_mode' => 'private')
    expect(HTTParty).to receive(:post) do |url, options|
      expect(url).to eq("https://graph.instagram.com/v23.0/#{ig_id}/messages")
      expect(JSON.parse(options[:body])['recipient']).to eq('comment_id' => 'c1')
      ok_response('message_id' => 'dm-1')
    end

    described_class.new(message: message).perform

    expect(message.reload.source_id).to eq('dm-1')
  end
end
