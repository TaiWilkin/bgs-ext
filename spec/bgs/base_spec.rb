# frozen_string_literal: true

require 'bgs'

# rubocop:disable Metrics/BlockLength
describe BGS::Base do
  let(:file_number) { '123456789' }
  let(:bgs_base) do
    BGS::TestBase.new(
      env: 'beplinktest',
      application: 'TEST_APP',
      client_ip: '127.0.0.1',
      client_station_id: 283,
      client_username: 'VACOUSERT',
      forward_proxy_url: nil,
      jumpbox_url: nil,
      external_uid: 'mytestuid',
      external_key: 'mytestkey',
      log: true
    )
  end

  # Build Savon::SOAPFaults how the library builds them.
  # https://github.com/savonrb/savon/blob/e76ecc00b84b998b012ecc33b55ca1edd443ec55/spec/savon/soap_fault_spec.rb
  let(:response_body) { nil }
  let(:http_response) { HTTPI::Response.new(500, {}, response_body) }
  let(:nori) { Nori.new(strip_namespaces: true, convert_tags_to: ->(tag) { tag.snakecase.to_sym }) }
  let(:soap_fault) { Savon::SOAPFault.new(http_response, nori) }
  let(:timeout_error) { Errno::ETIMEDOUT.new }

  context 'it should properly sets the header method' do
    it 'sets the external keys in the header' do
      header_fixture = File.read('spec/fixtures/soap_header.xml')
      expect(bgs_base.send(:header).to_s).to eq(header_fixture)
    end
  end
  context 'When Savon::Client receives a connection timeout error' do
    it 're-tries one time' do
      allow_any_instance_of(Savon::Client).to receive(:call).and_raise(timeout_error)
      expect(bgs_base).to receive(:client).twice.and_call_original
      expect { bgs_base.test_request(:method) }.to raise_error(Errno::ETIMEDOUT)
    end
  end

  context 'When Savon::Client.call() raises a generic Savon::SoapFault' do
    let(:response_body) do
      %(<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
   <soap:Body>
      <soap:Fault>
         <faultcode>soap:Server</faultcode>
         <faultstring>Fault occurred while processing.</faultstring>
      </soap:Fault>
   </soap:Body>
</soap:Envelope>)
    end

    it 'raises a Savon::SOAPFault' do
      allow_any_instance_of(Savon::Client).to receive(:call).and_raise(soap_fault)
      expect(bgs_base).to receive(:client).once.and_call_original
      expect { bgs_base.test_request(:method) }.to raise_error do |error|
        expect(error.class).to eq Savon::SOAPFault
        expect(error.message).to eq '(soap:Server) Fault occurred while processing.'
      end
    end
  end

  context 'when Savon::SoapFault with a transient ShareException message' do
    let(:message) { 'Connection reset by peer' }
    let(:response_body) do
      %(<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
   <soap:Body>
      <soap:Fault>
         <faultcode>soap:Server</faultcode>
         <faultstring>Fault occurred while processing.</faultstring>
         <Detail>
            <ShareException>
              <Message>#{message}</Message>
            </ShareException>
         </Detail>
      </soap:Fault>
   </soap:Body>
</soap:Envelope>)
    end

    it 'raises a transient BGS::ShareError' do
      allow_any_instance_of(Savon::Client).to receive(:call).and_raise(soap_fault)

      expect { bgs_base.test_request(:method) }.to raise_error do |error|
        expect(error.class).to eq BGS::ShareError
        expect(error.message).to eq message
        expect(error.code).to eq 500
        expect(error).to be_ignorable
      end
    end
  end

  context 'when Savon::SoapFault with a non-transient ShareException message' do
    let(:message) { 'not transient' }
    let(:response_body) do
      %(<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
         <soap:Body>
            <soap:Fault>
               <faultcode>soap:Server</faultcode>
               <faultstring>Fault occurred while processing.</faultstring>
               <Detail>
                  <ShareException>
                    <Message>#{message}</Message>
                  </ShareException>
               </Detail>
            </soap:Fault>
         </soap:Body>
      </soap:Envelope>)
    end

    it 'raises a non-transient BGS::ShareError' do
      allow_any_instance_of(Savon::Client).to receive(:call).and_raise(soap_fault)

      expect { bgs_base.test_request(:method) }.to raise_error do |error|
        expect(error.class).to eq BGS::ShareError
        expect(error.message).to eq message
        expect(error.code).to eq 500
        expect(error).to_not be_ignorable
      end
    end
  end

  context 'When BGS::ClaimantWebService.find_flashes() raises a logon not found error' do
    let(:fault_string) { 'Logon ID VACOHSOLO Not Found' }
    let(:response_body) do
      %(<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
         <soap:Body>
            <soap:Fault>
               <faultcode>soap:Server</faultcode>
               <faultstring>#{fault_string}</faultstring>
            </soap:Fault>
         </soap:Body>
      </soap:Envelope>)
    end
    let(:error_string) do
      # rubocop:disable Layout/LineLength
      "#{fault_string} in the Benefits Gateway Service (BGS). Contact your ISO if you need assistance gaining access to BGS."
      # rubocop:enable Layout/LineLength
    end

    it 'BGS::Base raises a BGS::PublicError that has a public_message' do
      allow_any_instance_of(Savon::Client).to receive(:call).and_raise(soap_fault)
      expect { bgs_base.test_request(:method) }.to raise_error do |error|
        expect(error).to be_a(BGS::PublicError)
        expect(error).to respond_to(:public_message)
        expect(error.public_message).to eq(error_string)
      end
    end
  end

  context 'base client' do
    it 'should set the host based upon the forward proxy url' do
      base = BGS::TestBase.new(
        env: 'beplinktest',
        application: 'TEST_APP',
        client_ip: '127.0.0.1',
        client_station_id: 283,
        client_username: 'VACOUSERT',
        forward_proxy_url: 'http://localhost:1337',
        jumpbox_url: nil,
        external_uid: 'mytestuid',
        external_key: 'mytestkey',
        log: true
      )
      expect(base.send(:client).wsdl.endpoint).to eq('http://localhost:1337/TestBaseBean/TestBase')
    end
  end

  context 'with a provided logger' do
    before(:all) do
      @log_out = StringIO.new
      @logger = Logger.new(@log_out)
      BGS.configure do |config|
        @old_logger = config.logger
        @old_log_enabled = config.log
        config.logger = @logger
        config.log = true
      end
    end

    after(:all) do
      BGS.configure do |config|
        config.logger = @old_logger
        config.log =  @old_log_enabled
      end
    end

    before do
      @log_out.truncate(0)
    end

    it 'should log to provided logger' do
      service = BGS::Services.new(
        external_uid: 'something',
        external_key: 'something'
      )

      # arbitrary endpoint in order for debug and info messages to be generated
      VCR.use_cassette('award/find_award_by_file_number') do
        response = service.awards.find_award_by_file_number('123345566', '999999999')
        expect(response[:gross_amt]).to eq('0.0')
      end
      expect(@log_out.string).not_to be_empty
      expect(@log_out.string).to match(/D, \[.+\] DEBUG -- /)
      expect(@log_out.string).to match(/I, \[.+\]  INFO -- /)
    end
  end

  context 'mock responses' do
    let(:mock_base) do
      BGS::TestBase.new(
        env: 'beplinktest',
        application: 'TEST_APP',
        client_ip: '127.0.0.1',
        client_station_id: 283,
        client_username: 'VACOUSERT',
        external_uid: 'test_user_123',
        external_key: 'test_key',
        mock_responses: true
      )
    end
    let(:mock_location) { '/tmp/bgs_mocks' }
    let(:mock_method) { :find_person }
    let(:mock_data) { { person_id: '12345', first_name: 'John', last_name: 'Doe' } }

    before do
      BGS.configure do |config|
        @old_mock_location = config.mock_response_location
        config.mock_response_location = mock_location
      end
    end

    after do
      BGS.configure do |config|
        config.mock_response_location = @old_mock_location
      end
      FileUtils.rm_rf(mock_location)
    end

    context 'when mock_responses is enabled' do
      context 'and a mock file exists for the identifier' do
        before do
          mock_file_path = "#{mock_location}/test_base/#{mock_method}/test_user_123.json"
          FileUtils.mkdir_p(File.dirname(mock_file_path))
          File.write(mock_file_path, mock_data.to_json)
        end

        it 'returns the mocked response from the file' do
          response = mock_base.test_request(mock_method)
          expect(response.body).to eq(mock_data)
        end

        it 'does not call the Savon client' do
          expect_any_instance_of(Savon::Client).not_to receive(:call)
          mock_base.test_request(mock_method)
        end
      end

      context 'and a mock file exists with a custom identifier' do
        let(:custom_identifier) { 'custom_id_456' }
        before do
          mock_file_path = "#{mock_location}/test_base/#{mock_method}/#{custom_identifier}.json"
          FileUtils.mkdir_p(File.dirname(mock_file_path))
          File.write(mock_file_path, mock_data.to_json)
        end

        it 'returns the mocked response using the custom identifier' do
          response = mock_base.test_request(mock_method, nil, custom_identifier)
          expect(response.body).to eq(mock_data)
        end
      end

      context 'and no mock file exists for the identifier but a default exists' do
        before do
          mock_file_path = "#{mock_location}/test_base/#{mock_method}/default.json"
          FileUtils.mkdir_p(File.dirname(mock_file_path))
          File.write(mock_file_path, mock_data.to_json)
        end

        it 'falls back to the default mock file' do
          response = mock_base.test_request(mock_method)
          expect(response.body).to eq(mock_data)
        end
      end

      context 'and no mock file exists at all' do
        it 'raises an error with the expected file path' do
          expected_default_path = "#{mock_location}/test_base/#{mock_method}/test_user_123.json"
          expect do
            mock_base.test_request(mock_method)
          end.to raise_error(RuntimeError, "Mock response file not found: #{expected_default_path}")
        end

        it 'includes both the identifier-specific and default paths in the error flow' do
          # First it tries with the identifier, then with 'default', then raises
          expect(File).to receive(:exist?).with(
            "#{mock_location}/test_base/#{mock_method}/test_user_123.json"
          ).and_return(false).at_least(:once)
          expect(File).to receive(:exist?).with(
            "#{mock_location}/test_base/#{mock_method}/default.json"
          ).and_return(false)

          expect do
            mock_base.test_request(mock_method)
          end.to raise_error(RuntimeError, /Mock response file not found/)
        end
      end
    end

    context 'generate_mock_filepath' do
      it 'generates the correct file path for a given method and identifier' do
        expected_path = "#{mock_location}/test_base/#{mock_method}/test_user_123.json"
        allow(File).to receive(:exist?).with(expected_path).and_return(true)
        actual_path = mock_base.send(:generate_mock_filepath, mock_method, 'test_user_123')
        expect(actual_path).to eq(expected_path)
      end

      it 'generates the correct file path for the default identifier' do
        expected_path = "#{mock_location}/test_base/#{mock_method}/default.json"
        allow(File).to receive(:exist?).with(expected_path).and_return(true)
        actual_path = mock_base.send(:generate_mock_filepath, mock_method, 'default')
        expect(actual_path).to eq(expected_path)
      end
    end

    context 'when mock_responses is disabled' do
      let(:non_mock_base) do
        BGS::TestBase.new(
          env: 'beplinktest',
          application: 'TEST_APP',
          client_ip: '127.0.0.1',
          client_station_id: 283,
          client_username: 'VACOUSERT',
          external_uid: 'test_user_123',
          external_key: 'test_key',
          mock_responses: false
        )
      end

      it 'calls the Savon client instead of reading from file' do
        allow_any_instance_of(Savon::Client).to receive(:call).and_return(
          Struct.new(:body).new(mock_data)
        )
        expect_any_instance_of(Savon::Client).to receive(:call).with(mock_method, message: nil)
        non_mock_base.test_request(mock_method)
      end
    end
  end
end
# rubocop:enable Metrics/BlockLength

# Helper class to allow us to test BGS::Base's private request() method.
module BGS
  class TestBase < BGS::Base
    def test_request(method, message = nil, identifier = nil)
      request(method, message, identifier)
    end
  end
end
