#ifndef LIBBITCOIN_NET_DIALECT_H
#define LIBBITCOIN_NET_DIALECT_H

#include <string>
#include <memory>

#include "bitcoin/net/serializer.hpp"
#include "bitcoin/net/messages.hpp"

namespace libbitcoin {
namespace net {

class dialect;
typedef std::shared_ptr<dialect> dialect_ptr;

class dialect
{
public:
    virtual serializer::stream to_network(
            message::version version) const = 0;
    virtual message::header header_from_network(
            const serializer::stream& stream) const = 0;
    virtual message::version version_from_network(
            const serializer::stream& stream) const = 0;
};

class original_dialect : public dialect
{
public:
    // Create stream from message
    serializer::stream to_network(message::version version) const;

    // Create header/messages from stream
    message::header header_from_network(
            const serializer::stream& stream) const;

    message::version version_from_network(
            const serializer::stream& stream) const;
};

} // net
} // libbitcoin

#endif
