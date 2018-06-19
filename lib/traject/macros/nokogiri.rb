module Traject
  module Macros
    module Nokogiri

      def default_namespaces
        @default_namespaces ||= (settings["nokogiri_reader.default_namespaces"] || {}).tap { |ns|
          unless ns.kind_of?(Hash)
            raise ArgumentError, "nokogiri_reader.default_namespaces must be a hash, not: #{ns.inspect}"
          end
        }
      end

      def extract_xpath(xpath, namespaces = {}, to_text: true)
        if namespaces && namespaces.length > 0
          namespaces = default_namespaces.merge(namespaces)
        else
          namespaces = default_namespaces
        end

        lambda do |record, accumulator|
          result = record.xpath(xpath, namespaces)
          result =  if to_text
                      # take all matches, for each match take all
                      # text content, join it together separated it with spaces
                      result = result.collect { |n| n.xpath('.//text()').to_a.join(" ") }
                    else
                      # just put all matches in accumulator as Nokogiri::XML::Node's
                      result = result.to_a
                    end

          accumulator.concat result
        end
      end
    end
  end
end
