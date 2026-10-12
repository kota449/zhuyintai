#import "KenLMQueryBridge.h"

#include "../Vendor/KenLMQuerySource/lm/config.hh"
#include "../Vendor/KenLMQuerySource/lm/model_type.hh"
#include "../Vendor/KenLMQuerySource/lm/virtual_interface.hh"

#include <memory>
#include <string>
#include <vector>

namespace lm {
namespace ngram {
base::Model *LoadVirtual(
    const char *file_name,
    const Config &config = Config(),
    ModelType if_arpa = PROBING
);
}  // namespace ngram
}  // namespace lm

namespace {

std::vector<std::string> TokenizeCharacters(NSString *text) {
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(
                              NSString * _Nullable substring,
                              NSRange substringRange,
                              NSRange enclosingRange,
                              BOOL * _Nonnull stop
                          ) {
                              (void)substringRange;
                              (void)enclosingRange;
                              (void)stop;
                              if (substring.length == 0) { return; }
                              [tokens addObject:substring];
                          }];

    std::vector<std::string> result;
    result.reserve(tokens.count);
    for (NSString *token in tokens) {
        result.emplace_back(token.UTF8String ?: "");
    }
    return result;
}

NSError *KenLMBridgeError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:@"KenLMQueryBridge"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

}  // namespace

@interface KenLMQueryBridge () {
    std::unique_ptr<lm::base::Model> _model;
}
@end

@implementation KenLMQueryBridge

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                     error:(NSError * _Nullable * _Nullable)error {
    self = [super init];
    if (!self) { return nil; }

    try {
        lm::ngram::Config config;
        config.show_progress = false;
        config.arpa_complain = lm::ngram::Config::NONE;
        _model.reset(lm::ngram::LoadVirtual(modelPath.fileSystemRepresentation, config));
    } catch (const std::exception &exception) {
        if (error) {
            *error = KenLMBridgeError(
                1,
                [NSString stringWithFormat:@"Failed to load KenLM model: %s", exception.what()]
            );
        }
        return nil;
    } catch (...) {
        if (error) {
            *error = KenLMBridgeError(2, @"Failed to load KenLM model for an unknown reason.");
        }
        return nil;
    }

    if (!_model) {
        if (error) {
            *error = KenLMBridgeError(3, @"KenLM returned a null model pointer.");
        }
        return nil;
    }

    return self;
}

- (nullable NSNumber *)conditionalLog10WithContext:(NSString *)context
                                         candidate:(NSString *)candidate {
    if (!_model || candidate.length == 0) { return nil; }

    try {
        const auto &vocabulary = _model->BaseVocabulary();
        std::vector<char> stateBufferA(_model->StateSize());
        std::vector<char> stateBufferB(_model->StateSize());
        void *currentState = stateBufferA.data();
        void *nextState = stateBufferB.data();
        _model->BeginSentenceWrite(currentState);

        for (const auto &token : TokenizeCharacters(context)) {
            const auto wordIndex = vocabulary.Index(token);
            _model->BaseScore(currentState, wordIndex, nextState);
            std::swap(currentState, nextState);
        }

        double score = 0.0;
        for (const auto &token : TokenizeCharacters(candidate)) {
            const auto wordIndex = vocabulary.Index(token);
            score += _model->BaseScore(currentState, wordIndex, nextState);
            std::swap(currentState, nextState);
        }

        return @(score);
    } catch (...) {
        return nil;
    }
}

@end
